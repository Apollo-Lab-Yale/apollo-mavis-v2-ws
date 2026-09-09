# Phase-15 — GELLO Manipulation（被动 leader 臂驱动 Manipulation Arm；Perception Arm 为外部 viewpoint；厨房数字孪生）

状态：**契约 = `docs/design/16-gello.md` v1.0（2026-09-09，binding）**；实现与本文件冲突时以 16-gello 为准并在报告中注明。
本 phase 建立在 phase-12 / 13 / 14（2026-09-09 上午已全部提交推送）之上。用户 2026-09-09 的原话见 16-gello §0；
主代理决策 D1–D10 见 §1，本文件只摘录。

## 用户决定（2026-09-09，binding）

1. landing 页第五张卡片 **GELLO Manipulation**（与 Teleop / Data Collection / Online DAgger / Inference 并列），wire `mode: gello`。
2. GELLO **只控制 Manipulation Arm**，关节空间；操作逻辑与 teleop 相近（v1 不录制）。**键盘 ←/→ 仍然驱动 Manipulation Arm 的导轨**；
   GELLO 负责七个关节与夹爪。
3. GELLO 模式下 **Perception Arm 的动作由外部 publish**（policy 仓通过既有 dora 外部接口）；没人 publish 时 Perception Arm **停在 GELLO
   hold 位姿** J1–J7 `[2.646, -1.598, 0.018, 1.637, 0.25, 2.007, 0.029]` rad、rail `0.0`（与 Teleop / Data Collection 的默认初始位姿
   不同；2026-09-09 已核对与真机遥测一致到 1e-3）。
4. GELLO 模式的 **数字孪生不一样**：mavis_v2 之外加 **冰箱 GE GDE21ESKSS** 与 **GE 30" 自立式电炉灶**（用户口头也说了"洗碗机"，
   相机画面是灶台，且用户给了灶台型号，按灶台处理），冰箱侧面两个、正面一个、灶台一个 AprilTag 放到测量位置；孪生副本要能在真机相机上
   overlay 以核对对齐。
5. GELLO 是被动的、启动位姿任意，所以 session 启动前**先让 Manipulation Arm 走到 GELLO 位姿**；若该位姿会撞进厨房，**拒绝启动并说明
   碰撞对**，UI **显示虚拟臂撞在哪里**；调整 GELLO 后重试；无碰撞时点 **OK** 进入 session。
6. Cockpit 右侧 **clearance 列表不能再把下方 New episode 等按钮挤出视野**（有界、紧凑）。

## 主代理代用户定的决策（摘自 16-gello §1；实现按此执行，用户可推翻）

- **D1** wire：`mode: gello` + 非空 `SessionSpec.gello {viewpoint: auto|external|hold}`（默认 `auto`）；不接受 task / dataset / policy /
  online_dagger，`policy_source` 保持默认，`start_from` 只能 `keep_current`。
- **D2** leader 是 runtime 设备（`devices/gello.py` `GelloReader`，tracker 模式），新增 extra `[gello]`（dynamixel-sdk + pyserial），只在该模块懒导入。
- **D3** 接合状态机 `no_leader | out_of_sync | tracking | paused | motion`；只有 `tracking` 才跟随；其余全部 hold 上一条命令，**没有隐式运动**。
  ±2π 关节（1/3/5/7）在每次接合时展开到离实测最近的分支。
- **D4** 启动 = 检查 → 规划 → **逐臂**执行（`_execute_arms`，`arm_order`）→ 接合；`POST /api/gello/preview`（无 session）返回判定 + 红色高亮的 PNG。
- **D5** viewpoint 节点走既有 external policy 路径，但**只覆盖 view 一臂**：`SessionAnnounce.external_arms: ["view"]`（末尾追加的新字段），
  `action_names` 只有 view 块；`auto` 有兼容 spec 即挂载、spec 过期即 hold；`external` 启动时必须已挂载；`hold` 忽略总线；gello 模式发布 `obs_state`。
- **D6** 厨房是第二个场景 id `mavis_v2_kitchen`（`hidden: true`，`GET /api/scenes` 仍只有 mavis_v2）；电器用规格尺寸的 box 放在实测面上，
  AprilTag 是不可碰撞的贴图薄板；overlay 以轮廓线显示；lab render 可把 `twin_overlay.scene` 指到厨房。
- **D7** 场景声明 `graspable: [fridge_door_handle, fridge_drawer_handle, range_handle]`，gello session 对 Manipulation Arm 的夹爪白名单这些几何体。
- **D8** **真机放开 gello**（`_validate_hardware` 允许 teleop / collect / gello）；`hardware_session.armed` 照旧把关；Online DAgger 的 D7 不变。
- **D9** 键位：←/→ = Manipulation Arm 导轨；其余 held 键对 Manipulation Arm 无效；夹爪跟随 leader trigger；Tab / Z / 臂行 / Space / episode 键 nack；
  `R` 与 Go to profile 照常规划执行但先强制 `paused`。键表不改；Pause / Resume 是 Cockpit 按钮（动作 `gello_pause` / `gello_resume`）。
- **D10** 标定是无 session 的 REST：`POST /api/gello/calibrate {op: match_arm|gripper_open|gripper_closed|clear}`，偏置取 π/2 整数倍写
  `var/gello_calibration.json`；`joint_signs` 是 operator 配置。

## 事实（现状，2026-09-09）

- 适配器：`/dev/ttyUSB0` = FTDI FT232H `0403:6014`，`/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_FTAKROCJ-if00-port0`，`root:dialout 0660`，
  开发账户在 `dialout`。**总线上没有任何舵机应答**（协议 2.0 / 1.0，57600 … 4M 全扫，广播 ping 也无）——最可能是舵机电源未接。没有 udev 规则。
- 厨房测量（16-gello §3）：Perception Arm 腕部 D435i 彩色帧 + 45 帧深度中值对齐到彩色；tagStandard41h12 id 0/1/3/4；检测四边形边长 0.0931 m
  （印刷 tag 0.168 m，含一位白边的贴图板 0.205 m）；冰箱侧面 x = 0.075、门面 y = −1.027、灶台门面 y = −1.222、台面 z = 0.926；yaw = 0；
  两项一致性校验通过（台面深 0.604 vs 0.610；冰箱背面距墙 2.7 cm）。原始数据 `var/gello-kitchen-20260909/`。
- 相机位姿（twin，hold 位姿）：(0.460, 0.394, 1.579) m，光轴 (−0.243, −0.907, −0.343)；实际图像 = 模型相机 + `cx+21, cy+13`。
- 触及范围：Manipulation Arm 基线 y = −0.179，冰箱门/把手 y ≈ −1.03 / −0.98 在触及边缘，灶台在触及范围之外。
- clearance 列表：runtime 只发 5 对（`supervisor.py` `sweep[:5]`），UI `ClearanceReadout k=5`；长标签在 320 px 列里换行 2–3 行，且列表排在
  EpisodeControls 之上，侧栏没有高度上限——"变长"的是行高不是行数。
- 既有精确事实（读者地图，2026-09-09）：`Mode` 字面量在 core `protocol/session.py:16`；hardware 拒绝矩阵 `manager.py:1225-1229`；
  `_resolve_arms` `control/loop.py:819-841`；导轨键 `_rail_rate` `loop.py:1251-1264`，rail-only tick 保持关节 `1210-1228`；
  `GatedPolicyExecutor._resolve_arms` `dagger/loop.py:226-270`，`_policy_step` `306-339`；external stack `manager.py:3158-3260`
  （全臂 delta_ee 布局校验 `3193-3199`）；`obs_state` 模式门 `publishers.py:599-603`；`_start_from_worker` `manager.py:3317-3453`，
  `_execute_arms` `2394-2521`；`EnvironmentSpec` 只支持 plane|box（`descriptor.py:88-97`）；builder 环境几何 `builder.py:180-201`；
  MjSpec 文件贴图可编译且 `to_xml` 往返（内存贴图不行）；`geom_rgba` 在有 material 时被忽略（高亮要 `geom_matid=-1`）；
  overlay 环境几何自动进 group 4 只画轮廓（`twin_overlay.py:584-593`）。

## 范围

### 1. core

- `Mode` 加 `gello`；`GelloSessionConfig`；`SessionSpec.gello`（末尾）+ `_cross_field` 规则；`SessionInfo.gello`；
  `ActionName` 末尾追加 `gello_pause` / `gello_resume`（无参数）；`CommandSource.GELLO`；`GelloTelemetry` / `GelloViewpointTelemetry`
  （`TelemetryMsg.gello` 末尾）；REST 模型 `GelloInfo` / `GelloCalibrateRequest` / `GelloCalibrateResult` / `GelloPreviewRequest` /
  `GelloPreviewResult` / `GelloPairInfo`；`SessionAnnounce.external_arms: list[str] = []`（`online_dagger` 之后）。
- `export_schemas --out schemas/`，`--check` 干净；`tests/test_protocol.py` 的字段集与顺序 pin 同步更新；01-core §10/§11/§12/§14/§20。

### 2. sim

- `EnvironmentSpec`：`type: plane|box|mesh`、`mesh`、`scale`、`texture`、`collidable`、`group`；`SceneDescriptor.graspable` + `SceneMeta.graspable`；
  builder：`texturedir`、`add_texture/add_material/add_mesh`，`collidable: false → contype=conaffinity=0`。
- `assets/textures/tagStandard41h12_0000{0,1,3,4}.png`（704×704）；`assets/scenes/mavis_v2_kitchen.yaml`（16-gello §3 的 box、四块 tag 板、
  `cam_kitchen`、`graspable`、keyframe：view = hold 位姿、grip = mavis_v2 keyframe）；`ASSET_MANIFEST.json` 重生成。
- 测试：`test_mavis_v2_kitchen.py`（δ 0.008/0.025 × mic on/off 审计；与 mavis_v2 共用块逐字相等；graspable 可解析；tag 板不在监视对里；
  **从 `view_wrist_cam` 渲染厨房孪生并用 pupil-apriltags 检出 id 0/1/3/4、中心与真实检测差 ≤ 25 px**，`egl`）；descriptor 新字段测试；
  `test_registry.py` 仍只列 mavis_v2；03-sim §4 加厨房小节。

### 3. runtime

- `devices/gello.py`（`GelloReader`、`GelloSample`、fake 后端 `fake_set`、baud 扫描、跳变判无效、`status(now)`）；`RuntimeBus.gello`；
  `Runtime` 持有；pyproject extra `gello` + banned-api + per-file-ignore；AST 限制测试。
- `config.py` `GelloConfig`（16-gello §9.1）+ `TwinOverlayConfig.scene`；两份 configs 加块；`test_configs.py` pin。
- `gello/engage.py`（状态机、unwrap、tolerance、leash）、`gello/loop.py`（`GelloLoop`）、`gello/viewpoint.py`（`ViewpointSource`：
  兼容性判定、懒挂载 / 过期卸载 `ExternalPolicySource(arms_meta=[("view", True)])`）、`gello/preview.py`（缓存厨房 twin + 关节限位 +
  `check_config_violations` + 专用 EGL 线程渲染 `cam_kitchen`、红色高亮）、`gello/calibration.py`。
- `session/manager.py`：`_check_gello`（409 顺序见 16-gello §9.2）、gello bring-up（sim / hardware，`tracker=False`）、启动运动
  （规划 → `_start_from_worker` → `_execute_arms` 逐臂 → 接合）、`R` / goto / return 前强制 paused、`_validate_hardware` 放开 gello、
  `_session_facts`（`external_arms`、view 块布局）、`SnapshotPublisher` 模式门加 gello、hub 兼容性检查复用。
- REST：`GET /api/gello`、`POST /api/gello/calibrate`、`POST /api/gello/preview`；`ws_telemetry` 的 `gello` 块；`ws_control` 动作 nack 文案。
- 两份 contract golden（runtime + policy-node）同步；skill `references/contract.md` 提到 `external_arms`。
- 测试：16-gello §13 runtime 段（reader / engage / loop / manager / REST / sim e2e / dora e2e）。**永远不要在 lab 机上不带 conftest 假缝跑 runtime 套件。**

### 4. ui

- `Mode` / `MODES` / `MODE_LABELS` / `MODE_DESCRIPTIONS` / `MODE_ICONS`（新图标）/ 路由 / 页面 / `.launcher-grid` 五列；`launch.ts`
  （`REASON`、`validateLaunch`、`buildSpec("gello")`：`sim_scene|digital_twin_scene = GET /api/gello .scene_id`，`gello: {viewpoint}`）。
- `GelloSheet`（状态 / 标定 / viewpoint 选择 / 预览轮询 500 ms / Start 仅在 clear 可点 / 409 内显）；`GelloPanel`；Cockpit gello 分支
  （标题、ArmIndicator 禁用、无 JointPanel / EpisodeControls）；`KeymapOverlay` gello 过滤 + 说明文字；`rest.ts` 三个新客户端。
- **clearance 修复**：`ClearanceReadout` 4 行（常量）、单行省略号、`max-height` + 滚动；collect / dagger 里 `EpisodeControls` 移到读数之上。
- `npm run gen:sync && npm run gen:types && npm run gen:check`；vitest 更新（Landing / streams 四卡片 pin 改五）。

### 5. docs / deploy

- 16-gello（本 phase 的契约）；00-overview §4 第 5 条模式、§5 说明、§8 五卡片、§10 文档表；01-core；03-sim §4；04-runtime §5/§6/§13/§14；
  05-ui §3/§8；11-safety §2 T11 / §13；14-dora §4/§5（`external_arms`、gello 发布 obs）；DEPLOYMENT S2/S4/S5/S7/S8.2/S11（udev 0403:6014、
  latency_timer、knobs `GELLO_BACKEND` / `GELLO_USB_SERIAL` / `GELLO_BAUD` / `TWIN_OVERLAY_SCENE`）；`render-lab-config.sh` + `mavis-dev.sh`；
- `scripts/deploy/install-stack.sh` 的 `uv sync` 加 `--extra gello`；DEPLOYMENT S3/S9 同步。
- README 状态表 + 依赖段；CLAUDE.md 指针与规则（其 Work-in-progress (2026-09-08) 一节已过时：五仓 2026-09-09 05:46 已全部提交推送，dev runtime 为 PID 3869832）。

### Out of scope

录制（collect 变体）、可开合的冰箱门、真实电器网格、键表新键、Online DAgger 真机放开、Perception Arm 之外的任何外部控制。

## 交付物

五个子仓的实现 + 测试全绿；policy-node golden 同步；文档修订；`var/gello-kitchen-20260909/` 原始测量保留；本文件"实施记录"。

## 验收标准（命令必须真实跑通；只勾本记录亲自复核过的项）

- [ ] core：`uv run pytest -q` 全绿；`uv run python -m apollo_mavis_v2_core.protocol.export_schemas --check` 干净。
- [ ] sim：`MUJOCO_GL=egl uv run pytest -q` 全绿（含 `test_mavis_v2_kitchen.py` 的 tag 检测与双 δ 审计）；`REGISTRY.list()` 仍为 `['mavis_v2']`。
- [ ] runtime：`uv run pytest -q -m "not dora"` 全绿；`uv run pytest -q -m "dora and egl" tests/dora_bridge/test_e2e_gello_viewpoint.py` 通过
      （单独跑，机器上无其他 dora 套件）；`ruff check` 干净；`test_chokepoint` 通过（gello 模块不调用 `command_*`）。
- [ ] policy-node：`uv run pytest -q -m "not dora"` 全绿，golden 与 runtime 字节相同。
- [ ] ui：`npm run lint && npm run gen:check && npm test && npm run build` 全绿。
- [ ] 无 session：`curl :8765/api/gello` 返回 leader 状态；`POST /api/gello/preview` 在 sim 下返回 `clear` + PNG；把 fake leader 摆到会撞冰箱的位姿
      后返回 `collision` 且 `pairs` 含 `fridge_body`。
- [ ] sim 端到端：GELLO 卡片 → sheet → Start；`fake_set` 移动 leader，follower 以 cap 跟随；←/→ 只动导轨；Pause 后 leader 动而 follower 不动；
      `R` 后状态为 paused；End session 回初始位。
- [ ] 真机（用户在场；GELLO 通电、标定后）：`GET /api/gello` `connected`；Devices/sheet 里逐关节动 GELLO 检查符号；`match_arm` 标定；
      预览 clear → Start：Manipulation Arm 逐臂规划走到 GELLO 位姿、Perception Arm 走到 hold 位姿、状态 `tracking`；缓慢移动 GELLO 跟随；
      ←/→ 导轨；Pause / Resume；把 GELLO 举向冰箱看门禁 hold + `OUT OF SYNC`；`*_align` 叠加厨房轮廓与真机对齐（差 ≤ 3 cm，否则改 YAML）。

## 注意事项

- **不要改 operator 的东西**：键表（24 行）、controller_map、pose filter、速度默认 100 %、臂名、`mavis_v2` 仍是唯一暴露场景、translate frame 默认 world。
- 所有会动臂的路径都走 twin 规划 + 门禁 + **逐臂**执行；`teardown()` 无运动；GELLO 的任何 hold 都是"保持上一条命令"。
- `ArmSender` 是唯一 `command_*` 调用点；新模块不得调用。
- dora 测试不可并发；`pgrep -x dora`。
- 深度测得的电器面 ±3 cm；overlay 对齐后再改 YAML 数字，并同步 16-gello §3。
- viewpoint 源只在 session RUNNING 且 view 无规划运动时挂载（启动运动期间节点发的动作不计 late）；sim 下 GelloLoop 把 dq_max 降到 0.6 rad/s 的真机值。

## 实施记录（2026-09-09）

**各仓落地**（未提交；详见 16-gello §15.1）：core `git diff --stat` 17 文件 +610/−22 + 9 新文件（`protocol/gello.py`、7 个 schema、
`tests/test_gello_protocol.py`）；sim 10 文件 +230/−18 + `mavis_v2_kitchen.yaml`、四张 tag 贴图、`tests/test_mavis_v2_kitchen.py`、
`tests/test_environment_geoms.py`、`tests/data/kitchen_tags_20260909.json`；runtime 22 文件 +1186/−64 + `devices/gello.py`、
`gello/{calibration,engage,loop,viewpoint,preview}.py`、8 个新测试文件；ui 34 文件 +1857/−178 + `GelloSheet` / `GelloPanel` /
`CollisionBanner.test`；policy-node `contract.py` / golden / `test_contract.py` / skill `contract.md`；工作区 docs 00/01/03/04/05/10/11/14、
DEPLOYMENT、README、`install-stack.sh`、udev 脚本、render / dev 脚本。

**真实测试数**（审查修复后，2026-09-09）：core 482 passed（原 464）、`export_schemas --check` 干净；sim `MUJOCO_GL=egl` 213 passed / 1 skipped
（原 155）；runtime `-m "not dora"` 860 passed / 2 skipped / 2 failed（仅 `test_return_fuzz_mavis_v2[mic|nomic]` 既有的规划器超时预算问题，
不含 phase-15 也同样失败；`test_e2e_reset_pinched_sim` 满载时 1/2 概率 flake、单独跑通过），`test_e2e_gello_viewpoint` 单独 1 passed，
ruff 干净；policy-node 142 passed；ui 47 files / 486 tests，lint / gen:check / prettier / build 干净。修复前一轮为 runtime 849 / ui 476 / policy-node 141。

**与 16-gello 的偏差（代码为准）**：见 16-gello §15.2 十条（`GelloTelemetry` 共享设备半基类、`gello_motion` 运动窗口取代
`on_motion_end` 回调、preview 无 workcell 时 409、sim 参照姿态 = keyframe、`obs_state` 元数据名两臂向量、导轨键在任何状态都有效、
fake 后端不套标定、chokepoint 白名单 `tools/axis_purity_measure.py`、`action_source` 预留 5、tag 检测测试 2× 超采样且关麦克风）。

**验收核对**（2026-09-09，本记录亲自复核）：
- ✓ core / sim / ui 三条验收命令全绿（数字如上）。
- ✓ runtime 非 dora 套件除 4 个既有失败外全绿；dora gello e2e 单独通过；chokepoint 通过。
- ✓ policy-node golden 与 runtime 字节相同。
- ✓ 无 session 的 `GET /api/gello` / `POST /api/gello/preview`（sim：`clear` + PNG；hardware 无 workcell：409）——在 8766 端口的
  sim 烟测实例上实测。
- ✓ sim 端到端：`POST /api/session` gello → running + `tracking`；`gello_pause` / `gello_resume`；`switch_arm` / `episode_new` nack；
  ArrowLeft 3 s 只动导轨（0.650 → 0.338 m）；W/E/I/F 对关节无效；Perception Arm 停在 hold 位姿；DELETE 无运动。
  （`fake_set` 移动 leader 的跟随与 fridge 碰撞 409 由 `tests/test_e2e_gello.py` 覆盖。）
- [ ] 真机：待 GELLO 通电、udev 规则、`uv sync --extra gello`、render + 重启后由用户在场执行。

**审查**（2026-09-09，对抗式审查；全文见 16-gello §15.5，偏差编号 §15.2 第 11–19 条）：确认 21 项、驳回 5 项，21 项已全部在工作树修复（未提交）。
- 安全 / 控制环：sim `GelloLoop` 只降 `dq_max` 不降执行器 slew → 每个 waypoint 都被切角（改为 `sim_gello_caps` 同时降两者，双 waypoint 测试钉死）；
  夹爪对比私有"上次发送值"而非生效值 → 到位夹爪目标后不再跟随（改比 `_grip_frac`）；运动窗口内 `gello_resume` 被接受并预先解除闩锁（改为 nack）；
  R / goto 先暂停再在拒绝时 `resume()` 把落后的从动臂打成 out_of_sync（改为仅在接受后暂停）。
- 启动检查：硬件预览用陈旧 monitor 样本报 clear（改为要求连接状态 + 样本龄 ≤ `stale_s`，否则 `no_workcell` / 409）；unwrap 取最近分支不看关节限位
  （改为限位感知）；session 无 scene 时回落到裸单元孪生而预览用厨房（两者统一为 `gello.scene_id`）。
- 设备线程：未标定的真 leader 永远无法 `match_arm`（`fresh_sample(require_calibrated=False)` + `GelloSample.jump`）；波特扫描忽略 stop 且忙轮询
  0.8–1.4 s/速率（逐 id ping、每次 ping 前查 stop、`stop()` 覆盖一次最坏扫描）。
- viewpoint / dora：参考节点取 `arm_ids[0]` 的坐标系，UI 顺序（grip 先）下永远挂不上（规则：`external_arms` 非空时 `action_frame == frames[external_arms[0]]`，
  两个参考节点 + 两份 contract.md + 14-dora §5 同步，e2e 改为 UI 顺序且不传 `--action-frame`）；NaN 暂停在遥测里不可见（新增 `viewpoint.paused` / `paused_latched`）。
- 文档 / 合同：14-dora §4.1 `obs_state` 元数据措辞、core 注释 "not a GELLO session"（改为基类 nack "not a GELLO Manipulation session" 并钉死）、
  §12.1 监控对数 288/310 → 540/571、§5.4 sim 参照姿态 = keyframe。UI 侧 7 项（Resume/Pause 门控、轮询超时、初始焦点、footer 提示、D8 文案、
  no_leader 注释）由 UI 代理修复，见 05-ui。
- **审查后测试数**（2026-09-09，亲自复核）：runtime ruff 干净；审查指定的 16 个测试文件 182 passed；完整非 dora 套件 860 passed / 2 skipped /
  2 failed（仅既有的 `test_return_fuzz_mavis_v2[mic|nomic]`，14:05）；`test_e2e_gello_viewpoint` 单独 1 passed（前后 `pgrep -x dora` 均为空）；
  policy-node 142 passed；core `export_schemas --check` 干净。UI 侧数字由 UI 代理记录（05-ui）。
