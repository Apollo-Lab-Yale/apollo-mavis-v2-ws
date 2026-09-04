# Phase 02 — apollo-mavis-v2-sim（一）：资产、场景注册表、MjSpec 组合、SimWorkcell、离屏渲染

## 目标

搭建 `apollo-mavis-v2-sim` 仓库的地基：vendor 菜单库资产、编写 `xarm7_on_rail.xml` 子模型、
实现 scene registry 与 `MjSpec` 运行时组合器（1–3 臂）、实现把 sim 当机器人用的
`SimWorkcell`（实现 core 的 `WorkcellInterface`，独立 monotonic 步进线程），以及 EGL
离屏渲染线程。IK/twin/planner 留给 phase-03。

## 前置条件

- 依赖 phase：01（core 已冻结并可 `uv` 安装）。
- 必读设计文档：
  - `docs/design/00-overview.md` §3.2（scene registry / MjSpec 组合）、§3.3（WorkcellInterface）、§8（渲染）
  - `docs/design/03-sim.md`（本仓事实来源：包布局、资产清单、SimWorkcell/渲染细节）
  - `docs/design/10-frames-and-data.md`（TCP site 与坐标框架约定）
- 参考：`docs/research/mujoco-xarm7-sim.md`（全部实测数字出处）。

## 范围

包内（`apollo_mavis_v2_sim`，依赖 core + mujoco==3.12.0）：

- **Vendored 资产**（`assets/`，保留 BSD-3 LICENSE + 仓库根 `THIRD_PARTY_LICENSES.md`；
  每个上游目录写 `UPSTREAM` 记录 commit hash；`asset_path(*parts)` 统一访问器；
  `ASSET_MANIFEST.json` 记录每个资产的 sha256）：
  - menagerie `ufactory_xarm7`（唯一的臂+gripper MJCF 来源，含 2024-12 finger-pad 修复、
    `armature=0.1`、`link_tcp` site 在 `0 0 .172`）。
  - mavis_mujoco 的 `linear_motor_rail.stl` / `linear_motor_platform.stl` 与
    `d435_with_cam_stand.stl` + 腕相机位姿（`pos="0.07 0 0.05" quat="0 0.7071 0.7071 0" fovy="57"`）。
- **`xarm7_on_rail.xml` + `xarm7_fixed.xml`** 子模型：rail slide joint
  `range="0 0.65"`（**直接 [0, 0.65]，不做 ±0.325 重零点**；不是 mavis 的 0.74 m），
  轴为 rail 基座系 **+Y**；rail + menagerie 臂 + gripper + 腕相机；移除 menagerie
  `link_base` 的 `pos="0 0 .12"` 底座偏移；`<exclude body1="link_base" body2="link1"/>`
  （父体焊死到 world 时 MuJoCo 关闭 parent-child 自动过滤，会产生 dist≈0.0002 m 常驻
  contact）。MJCF 内部 qpos 布局为 `[rail, j1..j7]`（rail 是运动学祖先）— 这是
  **sim 私有细节**，由 `Addressing` 层在边界重排成 core 序（关节 `q[0:7]`，rail 末位 `q[7]`）。
- **Scene registry**（`scenes/registry.py` + `assets/scenes/*.yaml` 描述符）：
  `SceneMeta{id, description, n_arms, arm_ids, rail, wrist_cams, cameras,
  suitable_for: {"sim","twin"}}`；`SceneRegistry.list()/meta(id)/build(id, overrides)`；
  `SceneOverrides`（子集臂、per-arm base pose 覆盖、twin 的 `geom_inflation_m`）；
  至少提供 1 臂、2 臂、3 臂（带/不带 rail 组合）场景，多数场景 sim/twin 通用。
- **组合器**（`scenes/builder.py`）：`mujoco.MjSpec` 父 spec（timestep 0.002、
  `implicitfast`、`spec.visual.global_.offwidth=1920 / offheight=1080`、floor、光源、
  环境相机；option 只写在父 spec），对每臂 `spec.attach(child, prefix=f"{arm_id}_",
  frame=...)`；builder 从描述符写**一个合并的 keyframe 0（`initial`）**（per-arm
  `<arm>_home` key 会把其他臂清零，不能直接用）；产出
  `BuiltScene{meta, spec, model, xml: spec.to_xml(), addressing}`（xml 每 episode 归档，
  phase-07 消费）。`Addressing` 预解析 per-arm `qpos_adr/dof_adr/ctrl_adr`（均为 core 序）、
  `gripper_ctrl_adr`、`tcp_site_id`、`wrist_cam_id`、geom id 集合 — 热循环零名字查找。
- **SimWorkcell / SimArm**（`workcell.py`，实现 `WorkcellInterface`/`ArmInterface`）：
  自有 stepping 线程 — 100 Hz 命令 tick、`nsub = round(0.01/0.002) = 5` 子步、
  `mj_step(model, data, nstep=5)`、`time.monotonic()` 累加式配速（`next_t += CTRL_DT`，
  落后 >1 tick 时重新对齐）；`command_joints(q)` 接 core 序（rail 末位）写目标缓冲，
  经 `Addressing.ctrl_adr` 落到 `data.ctrl`；`get_state()` 返回与 hardware 驱动同构的
  `ArmState`（不阻塞物理线程，快照槽）；`mj_resetDataKeyframe(model, data, 0)` 复位；
  `inject_fault(arm_id, code)`（仅测试）+ `clear_errors()` 故障闩锁。
- **Gripper 映射**（`gripper.py`）：`GripperCommand.open_frac`（1 = 全开）↔ menagerie
  actuator ctrl 0–255：`open_frac_to_ctrl(f) = (1−f)·255`（**ctrl 0 = 开，255 = 闭**，
  驱动角 0.85 rad = 全闭）、`driver_q_to_open_frac`、`open_frac_to_meters(f) = f·0.085`。
- **SimCamera**（`cameras.py`）+ **RenderService**（`rendering.py`）：进程内唯一线程拥有
  全部 `mujoco.Renderer`（GL context 线程亲和）与每 source 一份私有 `MjData`；
  `register_source/add_stream(StreamSpec)/remove_stream/submit_state/latest`，深度 1
  latest-frame 槽；`render(out=预分配buffer)`；shutdown 时显式 `renderer.close()`。
  `MUJOCO_GL=egl` 必须在 import mujoco 前设置，但**由 runtime 入口负责**（本包
  `__init__` 不碰环境变量，渲染惰性初始化）；`MUJOCO_EGL_DEVICE_ID` 默认 GPU 0
  （渲染/推理共享 GPU 0，DAgger trainer 独占 GPU 1）。

Out of scope：`MinkIKSolver`、`DigitalTwin`、`ResetPlanner`、碰撞膨胀、
`tools/guardrail_check.py`（全部 phase-03）；JPEG 编码与 WS 推流（runtime，phase-05）。

## 交付物

- `apollo-mavis-v2-sim/pyproject.toml`（依赖 `apollo-mavis-v2-core`、`mujoco==3.12.0`、
  `mink==1.3.0`（phase-03 用，锁死在此）、numpy、pyyaml、pydantic）。
- `src/apollo_mavis_v2_sim/`：`assets/`（含 `scenes/*.yaml`）、`scenes/{descriptor,registry,
  builder,addressing}.py`、`workcell.py`、`cameras.py`、`rendering.py`、`gripper.py`
  按 `03-sim.md` §1 布局；`xarm7_on_rail.xml`/`xarm7_fixed.xml` + vendored 资产 +
  LICENSE/UPSTREAM/`THIRD_PARTY_LICENSES.md`/`ASSET_MANIFEST.json`。
- `tests/`：组合器（1/2/3 臂编译通过、命名前缀正确、attach keyframe 重索引、合并
  keyframe 0、to_xml 往返重编译、Addressing 切片 perturb-and-check FK 验证）、
  SimWorkcell（步进节拍、rail-last 边界重排、gripper 方向/rail clamp 映射、ArmState
  字段、fault 注入闩锁 + stop/start 恢复）、渲染 smoke（EGL headless 出帧、尺寸/
  干净关闭）；`@pytest.mark.egl`/`@pytest.mark.perf` 标记区分 CPU-only 与 GPU 跑道。
- benchmark 脚本 `benchmarks/bench_step_render.py`（打印 mj_step 与 render 耗时）。

## 验收标准

在 `apollo-mavis-v2-sim/` 内执行（机器：RTX 4090 + EGL headless）：

- [ ] `uv sync && uv run pytest` 全绿。
- [ ] `uv run python -c "from apollo_mavis_v2_sim.scenes.registry import REGISTRY; b=REGISTRY.build('<3臂场景id>'); print(b.model.nq)"`
      成功编译 3 臂场景；断言 actuator 名如 `<arm_id>_act1 ... <arm_id>_gripper`、
      keyframe 0 为合并的 `initial` 且 `model.key(0).qpos.shape == (nq,)`（per-arm
      `<arm_id>_home` key 亦存在于全 nq 索引）。
- [ ] rail joint `range` 检查：断言组合后每个 rail slide joint `range == (0, 0.65)`
      （**直接映射**，无 offset）；`Addressing` 测试断言：往 `command_joints` 喂
      rail-last 的 core 序向量，`data.qpos`/`data.ctrl` 中 rail-first 的 MJCF 槽位
      被正确写入。
- [ ] `benchmarks/bench_step_render.py`：3 臂 `mj_step` ≈ 38 µs/步量级（阈值 < 100 µs）；
      100 Hz tick 的 5 子步 < 0.5 ms — sim 有 ~50× 实时余量。
- [ ] 渲染：640×480 RGB 单相机 ≈ 0.61 ms/帧（阈值 < 2 ms，~1600 FPS 量级）；
      1920×1080 可渲染（offwidth/offheight 已抬高，`Renderer` 不抛
      `Image width > framebuffer width`）。
- [ ] SimWorkcell 步进测试：跑 3 s，实际 tick 数 = 300 ± 2（monotonic 配速无漂移）；
      注入 50 ms 人为阻塞后能重新对齐不追帧狂奔。
- [ ] gripper 方向测试：ctrl ∈ {0, 255} 下实测指尖间隙，断言 **ctrl 0 = 开、255 = 闭**、
      `open_frac_to_ctrl(1.0) == 0`，开度与 ctrl 单调（绝不凭记忆信方向）。
- [ ] `spec.to_xml()` 输出重新 `MjSpec.from_string` + compile 成功（episode 归档可复现）。
- [ ] `uv run python -c "import apollo_mavis_v2_sim"` 在未设 `MUJOCO_GL` 时不崩（渲染惰性初始化）。

## 注意事项

- `MUJOCO_GL=egl` 必须在 **import mujoco 之前**设置 — 生产路径由 runtime 入口负责
  （04-runtime §13.5）；本包渲染模块惰性 import，`__init__` 绝不改环境变量（测试/
  benchmark 自己 export）。EGL 解释器退出时的析构序 `EGLError` 噪声是良性的，但要在
  正常 shutdown 路径显式 `renderer.close()`。
- `MjSpec.attach` 会**复制 child 的全部 asset（无论是否被引用）** — 3 臂 `nmesh=48`，
  无害但别惊讶；parent/child 都写 `<option>` 时会有 `Attach conflict ... keeping parent value`
  警告：所有 option 只写在父 spec，用 `warnings.catch_warnings` 过滤。
- keyframe 重索引在 compile 时定稿；3.12 下连续 attach 3 次工作正常，但这是文档标注过的
  历史坑 — 测试里钉住。
- mavis 的 rail 行程是 0.74 m（`range="-0.37 0.37"`），真实 rail 是 **0.65 m** — 这是
  资产改造的第一要务；mavis 的 TCP site 在 0.165，menagerie 在 **0.172**，用 menagerie。
- mavis 的双文件 `<include>` + 手工后缀方案**不要复用**（asset 全局命名空间冲突正是
  MjSpec.attach 解决的问题）。
- 一个 GL context 只能在创建它的线程使用 — 全部 `Renderer` 归一个专用线程所有，
  绝不在 stepping 线程或 asyncio 线程里 render。
- 配速永远用 `time.monotonic()` 累加，不要数步数、不要 `sleep(0.01)` 裸循环 —
  GC/编码抖动会累积漂移。
- 菜单库 actuator 增益（kp 1500/1000/800）未对真机辨识过 — 保持原样并在 README 记录
  这一保真度风险（phase-09 校准议题）。
- 锁 `mujoco==3.12.0`：margin/gap 语义跨版本变过（phase-03 依赖它），Renderer 也在向
  Filament 迁移期。
