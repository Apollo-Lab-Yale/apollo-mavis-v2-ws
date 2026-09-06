# Phase-09d — 归零前的孪生规划（位置无关路径）、两臂常驻 session、Debug 页

状态：设计定稿 2026-09-05。本文件是 core / hardware / runtime / ui / docs 五层实现的**唯一契约**，修订
phase-09c 的三个决定（见下）。锚点见 `~/apollo/logs/phase-09c-map.md` 与 09c 的实现。

## 用户决定（2026-09-05，binding）

1. **两臂永远都在真机 session 里。** 去掉 "Include in session" 开关与 `hardware_session.default_arms`；
   `SessionSpec.arms` 必须等于硬件 workcell 配置的全部臂（否则 409 "hardware sessions include every configured arm"）。
   理由：数据集里多一臂的数组不占多少空间，而两路相机无论如何都要录。09c 的 D1（冻结未选中臂）**只保留给维护
   运动**（见 3），teleop session 不再有未选中臂。
2. **归零前先规划。** `home_rail` 若当前姿态整段行程扫掠不通过，不是拒绝了事，而是：用孪生（RRT-Connect
   `DigitalTwin.plan`）规划一条从当前姿态到"导轨安全姿态"的关节路径，路径的**每个路点都要对导轨全部 131 个位置**
   无碰撞（滑台位置未知，所以路径必须位置无关），然后：连接该臂驱动 → 在门禁下以 10% 速度执行路径 → 到位后归零
   导轨（关节保持）→ 归零后**保持该姿态**（拆除时抱闸）。全过程由操作员在 UI 上确认后触发，进度实时可见。
3. **任何场景下初始化到 starting profile 都必须基于孪生做到无碰撞。** 真机 session 的 `start_from=profile:<id>`
   走与 sim 同一条 `twin.plan` → `_op_execute_plan` 路径（此时导轨已归零、位置已知，规划精确）；规划失败 → session
   拒绝启动并给出原因。本阶段用 fake 验证真机路径确实走了规划器。
4. Welcome 页右上角的 "Devices" 链接改名 **Debug**（路由 `#/devices` 不变，页面标题 "APOLLO MAVIS V2 · Debug"，
   页内标题 "Debug — gamepad & tracker"）。

## 事实

- 孪生已有关节空间 RRT-Connect：`DigitalTwin.plan(PlanRequest) -> PlanResult`（`sim/twin.py:439`，`planner.py:78`
  `ResetPlanner`）；控制环已有执行预规划路点的入口 `ControlLoop._op_execute_plan`（`loop.py:1100`，start_from §5.2 用）。
- 09c 的 `RailSweepChecker`（`runtime/devices/rail_sweep.py`）做当前姿态的整段扫掠；`home_rail`（监视器路径）
  在姿态扫掠通过时不动关节只归零导轨；`_bringup_hardware` 能只连一部分臂并按 D1 冻结另一臂——这正是维护运动
  需要的机制。
- 2026-09-05 离线扫掠：两臂**当前**姿态整段行程都无碰撞（min clearance 0.1 m）。规划分支是为以后姿态不理想时准备的。
- 两条导轨都未归零；归零是全仓库唯一的运动类维护操作。

## 范围

### 1. core（additive）

- `protocol/maintenance.py`：
  ```python
  class PrePositionPlan(BaseModel):
      needed: bool                          # False = current posture already sweep-clear
      source: Literal["current", "keyframe", "home", "search"] = "current"
      target_q: list[float] = []            # 7 joints, rad
      waypoints: int = 0
      duration_s: float = 0.0               # at speed_scale 0.1
      checked_rail_positions: int = 0       # 131 when position-agnostic validation ran
      clear: bool = True                    # path clear for EVERY rail position
      detail: str = ""
  RailSweepVerdict.pre_position: PrePositionPlan | None = None
  MaintenanceStatus = Literal["done", "accepted", "refused"]
  ArmMaintenanceResult.status: MaintenanceStatus = "done"   # accepted = async job started (202)
  ArmMaintenanceResult.job_id: str | None = None
  MaintenancePhase = Literal["queued", "sweeping", "planning", "connecting", "positioning",
                             "homing", "verifying", "done", "failed"]
  class MaintenanceProgress(BaseModel):
      op: ArmMaintenanceOp; job_id: str; phase: MaintenancePhase; detail: str = ""
      progress: float = 0.0                 # 0..1
      started_at: float | None = None
  ```
  `protocol/hardware_monitor.py`：`ArmMonitorTelemetry.maintenance: MaintenanceProgress | None = None`。
- `SessionSpec` 不变（arms 全集由 runtime 校验）。schemas / 测试 / 01-core §12。

### 2. hardware

- `XArmDriver.home_rail() -> RailHomeOutcome`：对**已连接**（mode 1 发流保持关节）的驱动执行
  `set_linear_track_back_origin(wait=True, timeout=30, auto_enable=False)` → enable → speed → 读寄存器 →
  `pos_m` 播种 → `RailPhase.READY`；执行期间暂停 `rail.step()` 的 5 Hz 目标发送；只按寄存器判定；失败 → `RAIL_ERROR`
  + 事件。允许在 `connect()` 因 `RailNotHomedError` 拒绝之外的另一条路径：新增 `connect(allow_unhomed_rail=True)`
  （或等价的 `XArmDriverConfig.rail_homing: Literal["require_homed", "allow_unhomed"]`），仅供维护运动使用：
  未归零时不抛错、`dof` 仍为 8、`ArmState.q[7]` 为 `None`/NaN 标记未知（runtime 负责用 fallback 喂孪生并做位置无关检查）。
- 监视器路径的 `home_rail`（09c）保持不变。
- `FakeXArmAPI`/测试同步；02-hardware §5/§9。

### 3. runtime

- `hardware_session`：删除 `default_arms`；`_validate_hardware`：`sorted(spec.arms) == sorted(configured arms)` 否则 409。
- `devices/rail_sweep.py` 新增 `check_path(arm_id, waypoints, samples, rail_fallback_m) -> PathVerdict`
  （每个路点 × 目标臂 131 个导轨位置 × 另一臂样本/fallback；返回 clear、首个坏路点、坏导轨位置、碰撞对）。
- `devices/rail_homing.py` `RailHomingJob`（每次一臂，`job_id`，线程）：
  1. `sweeping`：`RailSweepChecker.check(current)` → clear → 走 09c 监视器路径归零（不动关节）→ `verifying` → `done`。
  2. 不 clear → `planning`：候选姿态依次 = 场景 keyframe 该臂的 7 关节、`<arm>_home` keyframe、（可选）以候选为中心的
     小范围采样；对每个候选：整段扫掠 clear **且** `twin.plan(current → candidate)` 成功 **且** `check_path` 全部导轨位置
     clear → 得到 `PrePositionPlan`；都不行 → `refused`，detail 给操作员建议（例如 "fold the arm toward the factory
     zero posture in Studio and retry"）。
  3. `connecting`：暂停监视器并 join → 只连该臂（`allow_unhomed_rail=True`，`speed_scale` 固定 0.1，另一臂按 D1
     冻结，门禁无条件、孪生中该臂导轨用 fallback——路径已做位置无关验证）；
  4. `positioning`：`loop._op_execute_plan(waypoints)`，等待完成；故障 → 中止；
  5. `homing`：`driver.home_rail()`（关节由发流保持）；
  6. `verifying`：寄存器 homed+enabled+无错、监视样本；拆除（D6：state 4 + 抱闸 → **姿态保持**）→ 监视器恢复 → `done`。
  任何异常 → `failed`，同样拆除与恢复。进度写入 `ArmMonitorTelemetry.maintenance`；最终 `ArmMaintenanceResult`
  存为 `last`。
- REST：`POST .../maintenance {op: home_rail}`：dry_run → 200 + verdict（含 `pre_position`，零写入）；非 dry_run 且
  `pre_position.needed == False` → 同步执行（09c 路径，≤ 45 s）返回 200；`needed == True` → 启动 `RailHomingJob`，
  **202** + `status: accepted, job_id`；`GET .../maintenance/last -> ArmMaintenanceResult | 404`；job 运行中：
  `POST /api/session` 409 "rail homing in progress"，其他维护 op 409。
- `start_from=profile` 在 `_bringup_hardware` 上：确认与 sim 同路径（`twin.plan` → `_op_execute_plan`），规划失败 →
  拆除 + 409 "profile motion not collision-free: <detail>"；fake 测试断言 `planner.plan` 被调用且路点被执行。
- 测试：`test_rail_homing_job.py`（fake：clear 分支、需要规划分支的全部阶段与失败回滚、位置无关检查拒绝）、
  `check_path` 单测、REST 202/last/409、arms 全集校验、profile 规划路径断言。04-runtime §5/§13.1/§13.3/§15。

### 4. ui

- Welcome 右上 "Devices" → "Debug"；`Devices.tsx` 标题与 `pageTitle("Debug")`；测试字符串同步。
- 删除 "Include in session" 开关及 `DEFAULT_HARDWARE_ARMS`；`SessionSpec.arms` = 硬件 workcell 全部臂；启动器原因
  `railNotHomed`/`armNotReady` 对任一臂生效（文案 "Perception Arm: rail not homed — use Home rail"）。
- `HomeRailSheet`：dry-run 后若 `pre_position.needed`：显示 "The arm will first move along a planned path
  (N waypoints, ~X s at 10 %) to a folded posture that clears the whole rail travel, then the rail homes, then the
  arm holds that posture." + 目标姿态（度）+ `.btn-destructive` 确认 → POST → 202 → 面板切到进度视图（phase 列表
  与 detail，来自 `telemetry.hardware_monitor.arms[].maintenance`）→ done/failed 后从 `/maintenance/last` 取结果
  → toast。`needed == False` 时沿用 09c 同步流程。
- 05-ui §8.1/§8.2/§9/§10/§12；测试。

### 5. docs

- 本文件；`phase-09c-hardware-session.md` 头部加"D1 仅用于维护运动、Include 开关已移除（09d）"；
  `docs/prompts/README.md` 09d 行；`CLAUDE.md`（两臂常驻 session；归零可能先做规划运动；Debug 页）；
  02-hardware、04-runtime、05-ui、11-safety（维护运动也走门禁）、DEPLOYMENT S7/S11。

### Out of scope

- 双臂同时归零；归零速度寄存器；除 keyframe/home 之外的复杂姿态搜索（保留 `search` 枚举给以后）。

## 验收标准

- 各仓库全绿。fake 全链路：当前姿态不 clear 的构造样本 → dry-run 给出 `pre_position.needed True` 与路点数 →
  非 dry-run → 202 → 进度经历 planning/connecting/positioning/homing/verifying/done → 监视器恢复；clear 样本 →
  同步 200；`spec.arms` 非全集 → 409；profile 规划失败 → 409。
- 真机（用户在场）：按 09c 的现场步骤，但 Home rail 面板会先告诉你是否需要预先移动机械臂。

## 注意事项

- 维护运动与 teleop session 互斥；进行中禁止其他维护 op 与 session。
- 位置无关检查是路径安全的**唯一**依据（执行时孪生里的导轨位置仍是猜的）；不得因为孪生门禁"通过"就跳过它。
- 归零后不做任何自动的"回到原姿态"：保持收拢姿态，等操作员下一步。
