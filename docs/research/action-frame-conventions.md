# Delta end-effector action conventions — what VLAs, world-action models and real-robot imitation datasets actually use

**Date:** 2026-09-04

**Sources actually read for this note** (primary only; fetched 2026-09-04 via
`gh api ... -H 'Accept: application/vnd.github.raw'` at `main` unless a tag is
given, or the arXiv HTML page; every claim below cites the file/URL and the
sentence or code line it rests on; anything not verified is marked UNVERIFIED):

- Papers (arXiv HTML): RT-1 2212.06817, RT-2 2307.15818, Open X-Embodiment
  2310.08864, Octo 2405.12213, OpenVLA 2406.09246, BridgeData V2 2308.12952,
  DROID 2403.12945, π0 2410.24164, FAST 2501.09747, UMI 2402.10329, Diffusion
  Policy 2303.04137, ACT 2304.13705, Mobile ALOHA 2401.02117, PerAct 2209.05451,
  RVT 2306.14896, Chain-of-Action 2506.09990, HPT 2409.20537, GR00T N1 2503.14734.
- Code: `google-research/robotics_transformer`, `octo-models/octo`,
  `openvla/openvla`, `google-deepmind/open_x_embodiment` (+ the public dataset
  spreadsheet, CSV export), `rail-berkeley/bridge_data_robot`,
  `rail-berkeley/hil-serl`, `droid-dataset/droid`, `droid-dataset/droid_policy_learning`,
  `mees/calvin`, `Physical-Intelligence/openpi`,
  `real-stanford/universal_manipulation_interface`, `real-stanford/diffusion_policy`,
  `tonyzhaozh/act`, `NVIDIA/Isaac-GR00T`, `huggingface/lerobot` (+ Hub
  `meta/info.json` of `lerobot/droid_1.0.1`, `HuggingFaceVLA/libero`,
  `lerobot/utokyo_xarm_pick_and_place`), `ARISE-Initiative/robosuite` (`main`
  and tag `v1.4.1`), `ARISE-Initiative/robomimic`, `Lifelong-Robot-Learning/LIBERO`,
  `stepjam/RLBench`, `peract/peract`, `haosulab/ManiSkill` (`main` = ManiSkill 3,
  tag `v0.5.3` = ManiSkill 2), `simpler-env/SimplerEnv`,
  `simpler-env/ManiSkill2_real2sim`, `Farama-Foundation/Metaworld`,
  `isaac-sim/IsaacLab`, `nickgkan/3d_diffuser_actor`.
- Ours (read-only): `docs/design/10-frames-and-data.md` §3.2–3.3, §6–7;
  `docs/design/01-core.md` (`integrate_twist` signature);
  `apollo-mavis-v2-core/src/apollo_mavis_v2_core/se3.py:229-238`
  (`integrate_twist`); `apollo-mavis-v2-runtime/src/apollo_mavis_v2_runtime/dagger/policy_runner.py:179-193`
  (`ActionAnchor.apply_delta`).

**Question.** MAVIS v2 stores `delta_ee` actions as *space-frame* increments:
anchored at the current **measured** TCP pose, expressed along the axes of the
per-arm recording frame (`arm_base` by default) — `p' = p + δp`,
`q' = exp(δr) ⊗ q` (10-frames §3.2). The alternative is a *body/tool-frame*
relative transform `T_tcp⁻¹ · T_target` — `p' = p + R_tcp δp`,
`q' = q ⊗ exp(δr)`. Which one do mainstream VLAs, world-action models and
real-robot imitation datasets actually use, and should we change or extend
what we store?

---

## TL;DR

- **Majority convention for per-tick delta-EE actions is the space-frame /
  base-axes / left-multiply rule MAVIS already uses.** Verified in code for
  every real-robot controller behind the big EE-delta corpora — BridgeData V2
  (`action2transform_local`: "the rotation is around the position of the
  end-effector (axes are the same as world)"), DROID
  (`add_angles: new_rot = delta_rot * source_rot`, `add_poses: lin_sum = delta[:3] + source[:3]`),
  HIL-SERL/SERL (`nextpos[3:] = (Rotation.from_rotvec(δ) * Rotation.from_quat(currpos[3:]))`),
  CALVIN/TACO `rel_actions_world` — and for every mainstream simulator's
  *default* EE-delta controller: robosuite `OSC_POSE` (LIBERO, robomimic,
  MimicGen; `goal_orientation = rotation_mat_error @ current_orientation`),
  RLBench delta mode `frame=WORLD`, ManiSkill 3 `root_translation:root_aligned_body_rotation`,
  Isaac Lab `pose_rel`, and SIMPLER's `ee_align`/`ee_align2` controllers that
  were system-identified to reproduce RT-1/Bridge behaviour.
- **Body/tool-frame relative transforms (`T_tcp⁻¹ · T_target`, right-multiply)
  are the convention of *chunk-relative trajectory* methods, not of per-tick
  delta datasets:** UMI (`out = inv(base_pose_mat) @ pose_mat`, one anchor for
  the whole chunk; its old space-frame `'rel'` mode is labelled
  `# legacy buggy implementation`), and Isaac-GR00T's `RELATIVE` EEF
  representation ("introduced in the UMI paper"; `T_relative = T_other^{-1} * T_self`).
  The only *default* per-tick tool-frame controller found is legacy ManiSkill 2
  (`frame: str = "ee"`), which ManiSkill 3 reverted to root-aligned. Tool-frame
  otherwise exists only as an opt-in (RLBench `RelativeFrame.EE`, ManiSkill 3
  `body_*`, robosuite `IK_POSE`, OpenVLA `droid_wristact_transform`).
- **The VLAs themselves do not pick a frame.** OXE: "we do not align the
  coordinate frames across datasets in which the end-effector is controlled ...
  the same action vector may induce very different motions for different
  robots." Octo only filters to "delta end-effector control" and aligns the
  gripper sign; OpenVLA adds q01/q99 → [−1, 1] normalisation; HPT: "we do not
  align or preprocess action space ... other than normalization." RT-1/RT-2/π0
  papers never state an EE frame; π0's own robots are joint-space.
- **Anchor:** measured-pose anchoring (ours) matches DROID, HIL-SERL, robosuite
  default `goal_update_mode="achieved"`, ManiSkill `use_target=False`, Isaac
  Lab, RLBench, and the Octo/OpenVLA relabelling of Bridge
  (`state[1:, :6] - state[:-1, :6]`). Bridge's own robot loop and SIMPLER's
  WidowX replay anchor on the previous *commanded* target instead.
- **Rotation parametrisation is the least uniform axis:** RT-1/Bridge/DROID/CALVIN
  store roll-pitch-yaw Euler differences; robosuite/Isaac Lab/HIL-SERL/SIMPLER
  use a rotation vector (our choice); RLBench a unit quaternion; UMI/GR00T/DROID
  policy learning rot6d; ManiSkill 3 parses its three rotation dims as XYZ
  Euler despite docs saying axis-angle.
- **Recommendation:** keep §3.2 as the single canonical stored form (space-frame,
  recording-frame axes, measured anchor, rotvec). Because the anchor is the
  *measured* pose that is itself stored in `observation.state`, the tool-frame
  delta, the absolute target, and a UMI/GR00T chunk-relative representation are
  all recoverable **losslessly offline** (`Δp_tool = R_tcpᵀ Δp_base`,
  `Δq_body = q_tcp⁻¹ ⊗ Δq_space ⊗ q_tcp`, §4.2). The reverse would not be
  true for a target-anchored scheme. Do not add a second stored action form.

---

## 1. The two conventions — exact math

Notation: `T_tcp = (R_tcp, p_tcp)` is the current TCP pose in the recording
frame F (for MAVIS: `arm_base:<arm_id>`, or `world` / `camera:<k>`, §2 of
10-frames). `q_tcp` is the same rotation as a unit quaternion. A 6-D delta is
`Δ = [Δp (3), Δr (3)]`, `ΔR = exp([Δr]×)`, `Δq = rotvec_to_quat(Δr)`. All
conventions below leave the gripper and rail scalars untouched.

### 1.1 Space-frame delta, anchored at the TCP (MAVIS §3.2)

```
p_target = p_tcp + Δp                    # Δp along F axes
R_target = ΔR · R_tcp                    # rotation about the TCP origin, axes of F
q_target = Δq ⊗ q_tcp                    # left-multiply
```

Equivalently, as one SE(3) operation: `T_target = T(p_tcp) · (ΔR, Δp) · T(p_tcp)⁻¹ · T_tcp`,
i.e. the delta is conjugated to the TCP origin before left-multiplying — this
is literally what Bridge's `action2transform_local` does
(`trans = Teef.dot(trans).dot(TransInv(Teef))`,
`bridge_data_robot/widowx_envs/widowx_envs/utils/transformation_utils.py:152-157`)
and what SIMPLER's `ee_align` does (`target_pose = delta_pose * prev_ee_pose_at_base;
target_pose.set_p(prev_ee_pose_at_base.p + delta_pos)`,
`ManiSkill2_real2sim/.../pd_ee_pose.py:202-205`). Note this is **not** the plain
homogeneous product `ΔT · T_tcp`, which would rotate about the *frame origin*
and make `Δp` depend on `p_tcp`; nobody uses that.

Recovering the delta from two poses: `Δp = p_target − p_tcp`,
`Δq = q_target ⊗ q_tcp⁻¹` (DROID `quat_diff: R.from_quat(target) * R.from_quat(source).inv()`,
`droid/misc/transformations.py:34-36`).

Frame change (10-frames §3.3): deltas transform as free vectors,
`Δp_B = R_BA Δp_A`, `Δr_B = R_BA Δr_A`; frame translations cancel.

### 1.2 Body/tool-frame relative transform (UMI, GR00T `RELATIVE`)

```
T_rel    = T_tcp⁻¹ · T_target  = ( R_tcpᵀ R_target ,  R_tcpᵀ (p_target − p_tcp) )
p_target = p_tcp + R_tcp · Δp_tool       # Δp_tool along the TOOL axes
R_target = R_tcp · ΔR_body               # rotation about the TCP origin, TOOL axes
q_target = q_tcp ⊗ Δq_body               # right-multiply
```

UMI: `out = np.linalg.inv(base_pose_mat) @ pose_mat` (forward) and
`out = base_pose_mat @ pose_mat` (backward),
`universal_manipulation_interface/diffusion_policy/common/pose_repr_util.py:62-63, 94-95`.
GR00T: `T_relative = invert_transformation(T0) @ Tt` (`gr00t/data/state_action/pose.py:72`)
and `T_absolute = T_ref @ T_relative` (`gr00t/data/state_action/action_chunking.py:651-652`).

Body-frame deltas are invariant to the choice of F (a change of world frame
cancels in `T_tcp⁻¹ T_target`), which is why they need no §3.3-style
conversion — and also why they cannot be interpreted without knowing `R_tcp`.

### 1.3 Conversion between the two (exact, per frame)

```
Δp_tool  = R_tcpᵀ · Δp_base                       Δp_base  = R_tcp · Δp_tool
Δq_body  = q_tcp⁻¹ ⊗ Δq_space ⊗ q_tcp             Δq_space = q_tcp ⊗ Δq_body ⊗ q_tcp⁻¹
Δr_body  = R_tcpᵀ · Δr_space   (rotvec form of the conjugation)
```

Derivation: `q_tcp ⊗ Δq_body = Δq_space ⊗ q_tcp` ⇒ `Δq_body = q_tcp⁻¹ ⊗ Δq_space ⊗ q_tcp`.
OpenVLA's DROID base→wrist transform is exactly this
(`# world to wrist: dT_pi = R^-1 dT_rbt`, `vel_t = (R_frame_inv @ velocity[:, :3][..., None])[..., 0]`,
`# world to wrist: dR_pi = R^-1 dR_rbt R`, `dR = R_frame_inv @ (dR @ R_frame)`,
`openvla/prismatic/vla/datasets/rlds/oxe/utils/droid_utils.py:49-54`), confirming
that the base-frame delta is the stored primitive and the wrist-frame variant is
derived.

### 1.4 Worked example — tool yawed 90°, command "+x"

Setup (base frame B): `p_tcp = (0.50, 0.00, 0.30) m`, `R_tcp = Rz(+90°)`
(`q_tcp = (w,x,y,z) = (0.7071, 0, 0, 0.7071)`). Tool +x̂ therefore points along
base +ŷ, tool +ŷ along base −x̂, tool ẑ = base ẑ.

**Translation, `Δp = (+0.05, 0, 0)`, `Δr = 0`:**

| convention | `p_target` | motion seen from the base |
|---|---|---|
| space-frame (§1.1) | `(0.55, 0.00, 0.30)` | +5 cm along base x̂ — independent of tool orientation |
| body-frame (§1.2) | `p_tcp + Rz(90°)·(0.05,0,0) = (0.50, 0.05, 0.30)` | +5 cm along base ŷ (the tool's own x̂) |

Identical numbers, motions 90° apart. To obtain the space-frame motion under the
body convention you must command `Δp_tool = R_tcpᵀ (0.05,0,0) = Rz(−90°)(0.05,0,0) = (0, −0.05, 0)`.

**Rotation, `Δr = (+0.10, 0, 0) rad`, `Δp = 0`:**

| convention | `q_target` | axis of the physical rotation |
|---|---|---|
| space-frame | `exp(0.10 x̂) ⊗ q_tcp` | base x̂ through the TCP origin |
| body-frame | `q_tcp ⊗ exp(0.10 x̂)` | tool x̂ = base +ŷ through the TCP origin |

Equivalent body delta for the space command: `Δq_body = q_tcp⁻¹ ⊗ exp(0.10 x̂) ⊗ q_tcp = exp(0.10 · Rz(−90°) x̂) = exp(0.10 · (0, −1, 0))`,
i.e. `Δr_body = (0, −0.10, 0)`. Check: tool ŷ = base −x̂, so −0.10 rad about tool ŷ
is +0.10 rad about base x̂. ✓

With both parts non-zero the body decomposition uses the *current* `R_tcp` for
the translation (`T_tcp · (ΔR_body, Δp_tool) = (R_tcp ΔR_body, p_tcp + R_tcp Δp_tool)`),
so the two conversions in §1.3 are independent and can be applied per frame.

---

## 2. Survey table

Legend for "axes": **base/world** = space-frame, Δp added along F axes, ΔR
left-multiplied about the TCP origin (§1.1); **tool** = body-frame relative
transform (§1.2); **abs** = absolute target pose in F; **joint** = joint space.
"Anchor" = the pose the delta is composed onto. Confidence reflects whether the
frame statement comes from code (high) or is inferred (low/medium).

| system | action space | axes (base/world vs tool) | anchor | rotation parametrisation | evidence |
|---|---|---|---|---|---|
| **BridgeData V2** robot stack (`rail-berkeley/bridge_data_robot`, WidowX 250) | 7-D delta EE `[dx,dy,dz, droll,dpitch,dyaw, gripper]` at 5 Hz | **base/world** (space-frame) | robot loop: previous **commanded** target (`get_target_state()`); Octo/OpenVLA relabel to **measured** state differences | Euler rpy deltas → rotation matrix | `widowx_envs/utils/transformation_utils.py:142-158` docstring: "actions: [xyz deltas, and euler rotation angles, grasp_action], the rotation is around the position of the end-effector (axes are the same as world)"; `trans = Teef.dot(trans).dot(TransInv(Teef))`. `widowx_envs/base/robot_base_env.py:182-185`: `prev_transform, prev_gripperstate = self.get_target_state(); delta_transform, ... = tr.action2transform_local(action, self._controller.get_cartesian_pose()[:3]); next_transform = delta_transform.dot(prev_transform)` (left-multiply). Paper 2308.12952 §4: "6D Cartesian end-effector motion, corresponding to relative changes in pose" — frame not named. "world" == fixed WidowX base is inferred (bolted arm), UNVERIFIED in text. Confidence: high (code). |
| **DROID** dataset + teleop stack (`droid-dataset/droid`) | RLDS `action`(7) = 6 joint velocities + gripper; `action_dict.cartesian_velocity`(6) (what OpenVLA uses), `cartesian_position`(6) = commanded absolute; 15 Hz | **base** (space-frame) | current **measured** `robot_state["cartesian_position"]` each step | Euler `'xyz'` (scipy extrinsic) for `cartesian_*`; rot6d in `droid_policy_learning` | `droid/misc/transformations.py:59-70`: `add_angles: new_rot = delta_rot * source_rot`; `add_poses: lin_sum = delta[:3] + source[:3]`; `:34-36 quat_diff = R.from_quat(target) * R.from_quat(source).inv()`. `droid/franka/robot.py:216-220`: `cartesian_delta = self._ik_solver.cartesian_velocity_to_delta(action[:-1]); action_dict["cartesian_position"] = add_poses(cartesian_delta, robot_state["cartesian_position"])`. Paper 2403.12945 App. B: "robot end-effector pose and velocity in robot base frame (6D)"; §V-A: paper policies "produce absolute robot end-effector translation, rotation, and gripper actions". Hub `lerobot/droid_1.0.1` `meta/info.json`: `action` shape [8] = joint_0..6 + gripper; `action.cartesian_velocity` names `[x,y,z,roll,pitch,yaw]`. Confidence: high. |
| **HIL-SERL / SERL** `franka_env` (`rail-berkeley/hil-serl`) — the mechanism MAVIS 12-dagger cites | 7-D delta EE `[dxyz, rotvec, gripper]` in [−1,1], scaled | **base** (space-frame) | current **measured** `self.currpos` | rotation vector | `serl_robot_infra/franka_env/envs/franka_env.py:215-227`: `self.nextpos = self.currpos.copy(); self.nextpos[:3] = self.nextpos[:3] + xyz_delta * self.action_scale[0]; ... self.nextpos[3:] = (Rotation.from_rotvec(action[3:6] * self.action_scale[1]) * Rotation.from_quat(self.currpos[3:])).as_quat(); self._send_pos_command(self.clip_safety_box(self.nextpos))`. Identical to 10-frames §3.2. Confidence: high. |
| **CALVIN / TACO-Play** `rel_actions` (Franka; in OXE, consumed by Octo & OpenVLA) | 7-D relative: xyz (×50, clipped ±1) + Euler xyz (×20, clipped ±1) + binary gripper | **base/world** (`rel_actions_world`; a gripper-frame variant also exists but is not the one used) | current TCP | Euler xyz deltas | `mees/calvin dataset/README.md:80-84`: "tcp position (3): x,y,z in relative world coordinates normalized and clipped to (-1, 1) with scaling factor 50; tcp orientation (3): euler angles x,y,z in relative world coordinates ... scaling factor 20". `octo/data/oxe/oxe_standardization_transforms.py:105` and `openvla/.../oxe/transforms.py:152`: `trajectory["action"] = trajectory["action"]["rel_actions_world"]`. Confidence: high. |
| **RT-1** (Google robot, OXE `fractal20220817_data`) | 7-D arm delta (x,y,z,roll,pitch,yaw,gripper) + 3-D base + mode, each dim in 256 bins; RLDS `world_vector`(3), `rotation_delta`(3), 3 Hz | **base/world — inferred only** (field name + SIMPLER real2sim) | per-step delta on current EE pose; measured vs commanded UNVERIFIED | rpy Euler deltas (SIMPLER converts via `euler2axangle`) | Paper 2212.06817 §4: "The actions consist of seven dimensions for the arm movement (x, y, z, roll, pitch, yaw, opening of the gripper)"; §5.1: "each action dimension in RT-1 is discretized into 256 bins"; App. C.2: "3D position and rotational displacements of the remote are mapped to 6d displacements of the robot tool" — no frame statement anywhere. `robotics_transformer/transformer_network_test_set_up.py:166-174`: `action_spec.world_vector = BoundedTensorSpec((3,), minimum=-1., maximum=1.)`, `action_spec.rotation_delta = BoundedTensorSpec((3,), minimum=-np.pi/2, maximum=np.pi/2)`. `octo/.../oxe_standardization_transforms.py` `rt1_dataset_transform` concatenates `world_vector`, `rotation_delta`. SIMPLER maps RT-1 onto `frame="ee_align"` (see SIMPLER row). Confidence: medium (encoding high; frame UNVERIFIED in primary text). |
| **RT-2** | same encoding as RT-1, emitted as text tokens: "terminate Δpos_x Δpos_y Δpos_z Δrot_x Δrot_y Δrot_z gripper_extension" | not specified (inherits RT-1 controller) | not specified | Δrot_x/y/z (rpy-style) | Paper 2307.15818 §3.2: "We base our action encoding on the discretization proposed by Brohan et al. (2022) for the RT-1 model."; "6-DoF positional and rotational displacement of the robot end-effector"; "discretized into 256 bins uniformly". The word "coordinate" never appears; "frame" only as image frame. Confidence: high for encoding; frame UNVERIFIED. |
| **Open X-Embodiment** RLDS / RT-1-X / RT-2-X | coarsely aligned 7-D EE vector (x,y,z,roll,pitch,yaw,gripper) that is absolute, relative or velocity per source dataset; per-dataset normalisation + 256 bins | **mixed — explicitly NOT aligned** | per dataset | rpy per dataset | Paper 2310.08864 §IV-A: "We use a coarsely aligned action and observation space across datasets." ... "we do not align the coordinate frames across datasets in which the end-effector is controlled" ... "allow action values to represent either absolute or relative positions or velocities" ... "Thus, the same action vector may induce very different motions for different robots." README L35: "Each variable represents the absolute value, the delta change to the dimension value or the velocity of the dimension." Public spreadsheet (CSV export) has no frame column; "Action Space" takes only {EEF Position, EEF velocity, Joint position, ...}. Confidence: high. |
| **Octo** (`octo-models/octo`) | 7-D delta EE (xyz + rpy + gripper) for pretraining; datasets without delta-EE control removed; joint heads only at fine-tune (ALOHA 14-D) | **mixed** — per-dataset native, no frame conversion in transforms | per dataset; Bridge relabelled to measured state differences | rpy Euler deltas | Paper 2405.12213 §III-B: removed datasets "that do not use delta end-effector control"; gripper only aligned ("+1 means the gripper is open"); paper never states base vs tool. `octo/data/oxe/oxe_dataset_configs.py`: `EEF_POS = 1  # EEF delta XYZ + roll-pitch-yaw + gripper open/close`. `octo/data/utils/data_utils.py:396-403 relabel_actions`: "Relabels the actions to use the reached proprio instead"; `movement_actions = traj["observation"]["state"][1:, :6] - traj["observation"]["state"][:-1, :6]`. Confidence: high. |
| **OpenVLA** (`openvla/openvla`) | 7-D `EEF_POS` = delta XYZ + rpy + gripper; q01/q99 → [−1,1]; 256 uniform bins → least-used Llama tokens | **mixed** per source; DROID **base** by default (wrist variant optional) | current pose; Bridge relabelled to measured differences | rpy Euler deltas (`EEF_R6` rot6d variant for wrist-frame DROID) | Paper 2406.09246 §3.2: "we discretize each dimension of the robot actions separately into one of 256 bins" between "the 1st and 99th quantile"; §5.2 fn.3: "all other methods use relative position control"; no frame wording. `prismatic/vla/datasets/rlds/oxe/configs.py`: `EEF_POS = 1  # EEF Delta XYZ (3) + Roll-Pitch-Yaw (3) + Gripper Open/Close (1)`. `utils/data_utils.py:53`: `BOUNDS_Q99 ... # Normalize [quantile_01, ..., quantile_99] --> [-1, ..., 1]`; `:166-170 relabel_bridge_actions: movement_actions = state[1:, :6] - state[:-1, :6]`. `oxe/utils/droid_utils.py:66-71 droid_baseact_transform`: "DROID dataset transformation for actions expressed in *base* frame of the robot."; `:99` "*wrist* frame" variant via `R^-1 dT`, `R^-1 dR R` (§1.3). Confidence: high. |
| **π0 / π0.5 / openpi** (`Physical-Intelligence/openpi`) | joint-space for PI's own robots (UR5e 7, Franka 8, bimanual 14, mobile 16/17, zero-padded to 18); ALOHA 14 joints as deltas vs first state of chunk; DROID joint position/velocity; LIBERO: dataset's robosuite OSC_POSE deltas passed through | **joint** (own robots); **base/world** only via LIBERO/OXE source data | first state of each action chunk (joint deltas); LIBERO current measured EE (robosuite) | n/a (joint); LIBERO axis-angle | Paper 2410.24164 §IV: "q_t is a vector of joint angles"; §V-A: pad to "the largest robot in the dataset (18 in our case)"; words "end-effector", "Cartesian", "base frame" do not appear. `src/openpi/transforms.py DeltaActions`: "Repacks absolute actions into delta action space." `src/openpi/training/config.py:326-333`: "pi0 models are trained on delta actions (relative to the first state in each action chunk) ... In Libero, the raw actions in the dataset are already delta actions, so we *do not* need to apply a separate delta conversion"; `droid_rlds_dataset.py:21-25 class DroidActionSpace(Enum): JOINT_POSITION; JOINT_VELOCITY`. Confidence: high. |
| **π0-FAST** (FAST/FAST+ tokenizer) | same policy action spaces as π0; tokenizer: per-dim q01/q99 → [−1,1], DCT per dim, BPE (1024); FAST+ trained on joint, "end-effector world frame" and "end-effector camera frame" parametrisations | **mixed** (tokenizer-universal); source datasets kept "in their original form" | per source dataset | per source dataset | Paper 2501.09747 §V-B: "the 1st and 99th quantile of values in the training dataset for each action dimension maps to the range [−1,…,1]"; "we apply the discrete cosine transform to each action dimension separately". App. A: "multiple action space parametrizations: joint space, end-effector world frame, and end-effector camera frame"; OpenX, DROID, Bridge V2 "are included in their original form". Confidence: high. |
| **UMI** (`real-stanford/universal_manipulation_interface`) | chunk of EE poses relative to the current EE pose; 10-D per robot (pos3 + rot6d + gripper width); also for proprioception | **tool** (body-frame relative transform) | latest observed measured pose `pose_mat[-1]`, one anchor for the whole chunk | rot6d (`mat_to_pose10d`); raw axis-angle | `diffusion_policy/common/pose_repr_util.py:62-63`: `elif pose_rep == 'relative': out = np.linalg.inv(base_pose_mat) @ pose_mat`; `:94-95` backward `out = base_pose_mat @ pose_mat`; `:53-57` `'rel'`: `# legacy buggy implementation`, `rot = pose_mat[...,:3,:3] @ np.linalg.inv(base_pose_mat[:3,:3])` (the space-frame variant). `diffusion_policy/config/task/umi.yaml:88-89`: `obs_pose_repr: relative`, `action_pose_repr: relative # abs or rel or delta`. `dataset/umi_dataset.py:344-353`: `convert_pose_mat_rep(action_mat, base_pose_mat=pose_mat[-1], ...)`. Paper 2402.10329 PD2: "we represent all EE poses relative to gripper's current EE pose"; PD2.1: "a sequence of SE(3) transforms denoting the desired pose at t relative to the initial EE pose at t₀"; Fig. 6: "Delta action represents each action step relative to its immediate previous action, therefore accumulates error." Confidence: high. |
| **Diffusion Policy** real robot (`real-stanford/diffusion_policy`) | **absolute** EE target pose sequence (xyz + rotvec, UR5 TCP, 10 Hz waypoints → 125 Hz `servoL`) | abs, base (UR TCP frame) | none (absolute); SpaceMouse teleop integrates increments onto the previous commanded target, space-frame | rotation vector | `demo_real_robot.py`: `drot = st.Rotation.from_euler('xyz', drot_xyz); target_pose[:3] += dpos; target_pose[3:] = (drot * st.Rotation.from_rotvec(target_pose[3:])).as_rotvec()`. `real_world/real_env.py`: `self.robot.schedule_waypoint(pose=new_actions[i], target_time=new_timestamps[i])`; `episode['action'] = actions[:n_steps]`. `rtde_interpolation_controller.py:268`: `rtde_c.servoL(pose_command, ...)`. Paper 2303.04137 §4.2: "Diffusion Policy with a position-control action space consistently outperforms Diffusion Policy with velocity control". Base-frame claim relies on UR `servoL` semantics (UNVERIFIED here); paper App. D truncated in fetch. Confidence: high (absolute), medium (frame). |
| **ACT / ALOHA** (`tonyzhaozh/act`) and **Mobile ALOHA** | 14-D absolute joint positions (+2 base velocities for Mobile ALOHA) | **joint** | none (absolute) | n/a | Paper 2304.13705: "The action space is the absolute joint positions for two robots, a 14-dimensional vector."; "degraded performance when using delta joint positions as actions instead of target joint positions". README: "sim_env.py Mujoco + DM_Control environments with joint space control". Mobile ALOHA 2401.02117 §4: "The bimanual actions are formulated as target joint positions", "the base actions are formulated as target base linear and angular velocities". Confidence: high. |
| **robosuite `OSC_POSE`** (→ robomimic, MimicGen, RoboCasa, **LIBERO** which pins `robosuite==1.4.0`) | 6-D delta `[dx,dy,dz, ax,ay,az]` in [−1,1] → ±0.05 m / ±0.5 rad + gripper; `input_type: delta` (v1.5) / `control_delta: true` (v1.4) | **base/world** (v1.4: world; v1.5: `input_ref_frame` = `"base"` default or `"world"`; **no tool option** for OSC) | current **measured** EE (`goal_update_mode="achieved"` default; `"desired"` = previous target only in mobile-base mode) | axis-angle (rotvec) | `v1.4.1 robosuite/utils/control_utils.py:136,175-177`: `goal_position = current_position + delta`; `quat_error = trans.axisangle2quat(delta); rotation_mat_error = trans.quat2mat(quat_error); goal_orientation = np.dot(rotation_mat_error, current_orientation)`. `main robosuite/controllers/parts/arm/osc.py:98-100,136,159-162`: `input_ref_frame ... "base": actions are wrt to the robot body (i.e., the base) "world": actions are wrt the world coordinate frame`; default `input_ref_frame="base"`; `assert self.input_ref_frame in ["world","base"]`; `:338-341 goal_pos = self.world_to_origin_frame(self.ref_pos) + delta`. `docs/modules/controllers.rst:100-103`: "for OSC, the rotation axes are taken relative to the global world coordinate frame, whereas for IK, the rotation axes are taken relative to the end-effector origin". `LIBERO/requirements.txt:10 robosuite==1.4.0`; `libero/libero/envs/env_wrapper.py:17,47 controller="OSC_POSE"`. `robomimic/scripts/conversion/robosuite_add_absolute_actions.py` re-derives `actions_abs` with `control_delta=False`. Confidence: high. |
| **RLBench** `EndEffectorPoseViaPlanning`/`ViaIK` (PerAct, RVT, 3D Diffuser Actor, Act3D, Chain-of-Action substrate) | 7-D pose (xyz + unit quaternion) + gripper; `absolute_mode=True` default; delta mode with `frame=RelativeFrame.WORLD` (default) or `EE` | default **abs world**; delta+WORLD = **base/world** (space-frame); delta+EE = **tool** | delta modes: current **measured** tip pose | unit quaternion (xyzw) | `rlbench/action_modes/arm_action_modes.py:30-37`: `calculate_delta_pose: new_rot = Quaternion(a_qw, a_qx, a_qy, a_qz) * Quaternion(qw, qx, qy, qz); pose = [a_x + x, a_y + y, a_z + z] + [qx, qy, qz, qw]`; `:40 class RelativeFrame(Enum): WORLD = 0; EE = 1`; `:192 absolute_mode: bool = True, frame: RelativeFrame = RelativeFrame.WORLD`; `:210 relative_to = None if self._frame == RelativeFrame.WORLD else scene.robot.arm.get_tip()`. Confidence: high. |
| **PerAct / RVT / 3D Diffuser Actor / Chain-of-Action** (keyframe & trajectory policies) | absolute next-keyframe (or trajectory) EE pose + gripper (+ collision flag) | **abs**, robot base / world; 3DDA `relative=True` re-centres *positions* only along world axes | none (absolute) | PerAct/RVT: Euler in 5° bins; 3DDA rot6d; CoA quaternion | PerAct 2209.05451 §3.2: "Rotation is discretized into 5 degree bins for each of the three rotation axes"; App. B: "The point values are Cartesian coordinates in the robot's coordinate frame." RVT 2306.14896: "transform the perceived point clouds to the robot base frame before passing into RVT". `3d_diffuser_actor/diffuser_actor/trajectory_optimization/diffuser_actor.py convert2rel`: `pcd = pcd - center...; curr_gripper[..., :3] = curr_gripper[..., :3] - center` (rotation untouched); 3DDA paper text UNVERIFIED (fetch blocked). CoA 2506.09990: "Execution is command by absolute end effector poses." Confidence: high (code/papers), 3DDA paper medium. |
| **Isaac-GR00T** (N1/N1.5 paper + current repo) | per-embodiment heads; humanoid GR-1 absolute/relative joints; repo `ActionRepresentation {RELATIVE, DELTA, ABSOLUTE}`; DROID pretrain config `oxe_droid_relative_eef_relative_joint` = RELATIVE EEF `XYZ_ROT6D` + ABSOLUTE gripper + RELATIVE joints | **tool** for `RELATIVE` EEF (UMI-style `T_ref⁻¹ · T`); paper states no frame | last observed state `state[state_key][-1]` for the whole chunk (RELATIVE); DELTA = step-to-step | rot6d (`XYZ_ROT6D`) or rotvec (`XYZ_ROTVEC`); paper "axis-angle" | `gr00t/data/state_action/pose.py:662-675`: "Mathematically: T_relative = T_other^{-1} * T_self"; `:72 T_relative = invert_transformation(T0) @ Tt`. `action_chunking.py:651-652`: `# Compose transformations: T_absolute = T_ref @ T_relative`. `getting_started/data_config.md`: "`RELATIVE`: Actions are deltas from the current state (introduced in the UMI paper)", "Using relative actions will lead to smoother actions, but might suffer from drifting." `gr00t/data/state_action/droid_frame.py`: `DROID_EEF_ROTATION_CORRECT = [[0,0,-1],[-1,0,0],[0,1,0]]` post-multiplied so DROID EE rotations match the "egocentric TFG convention". Paper 2503.14734 §4.1 RoboCasa: "The action space is defined by the relative position and rotation of the end-effector"; App. E.2 "End-effector rotation actions are expressed in axis-angle representation" (one researcher read the PDF; the other could not — treat as medium). Confidence: high (code), medium (paper). |
| **LeRobot** (`huggingface/lerobot`, main 2026) EE processors + Hub datasets | default robots: absolute joints. `EEReferenceAndDelta`: `(delta_x/y/z, target_wx/wy/wz)` → absolute `ee.*` target; EE example datasets record **absolute** `ee.x..ee.wz`; HIL-SERL port outputs 3-D translation deltas, rotation hard-coded 0 | **hybrid**: translation along **base** (FK) axes, rotation **right-multiplied** (tool axes) | FK of current joints (`use_latched_reference=False`, RL) or pose latched at enable (`=True`, phone teleop) | rotation vector | `src/lerobot/robots/so_follower/robot_kinematic_processor.py:105,134-137`: `t_curr = self.kinematics.forward_kinematics(q_raw)`; `r_abs = Rotation.from_rotvec([wx, wy, wz]).as_matrix(); desired[:3, :3] = ref[:3, :3] @ r_abs; desired[:3, 3] = ref[:3, 3] + delta_p`; `:70 use_latched_reference: bool = (True)`. `src/lerobot/processor/delta_action_processor.py`: `# TODO (maractingi): add rotation`; `# For gamepad/keyboard, we don't have rotation input, so set to 0`. `examples/so100_to_so100_EE/record.py` action features from `ForwardKinematicsJointsToEE` → absolute EE pose. Hub `HuggingFaceVLA/libero` `action` [7] names `["actions"]`; `lerobot/utokyo_xarm_pick_and_place` `action` [7] `motor_0..6` (frame not recorded). Confidence: high; whether the right-multiply is intentional is ambiguous in source (variable is named `r_abs`). |
| **HPT** (Heterogeneous Pre-trained Transformers) | native per-dataset action via per-embodiment heads; element-wise [−1,1] normalisation only | **mixed**, no alignment | per dataset | per dataset | Paper 2409.20537: "we do not align or preprocess action space or observation space [55, 86] other than normalization"; §5.2 real robots differ in "different action spaces relative pose v.s. absolute pose". Confidence: high. |
| **SIMPLER / ManiSkill2_real2sim** (real-to-sim eval of RT-1, RT-2, Octo, OpenVLA) | 7-D `concat(world_vector, rot_axangle, gripper)`; Google robot `frame="ee_align"`, WidowX `frame="ee_align2", use_target=True`; RT-1-on-Bridge unnormalisation ±0.05 m / ±0.25 rad | **base** axes, rotation about EE origin (space-frame) — system-identified against the real controllers | Google robot: current measured EE (FK); WidowX: previous **target**, pivot at current EE position | axis-angle at the env boundary (Octo rpy → `euler2axangle`) | `simpler_env/utils/env/env_builder.py:20-26`: google_robot_static → `arm_pd_ee_delta_pose_align_interpolate_by_planner_...`; widowx → `arm_pd_ee_target_delta_pose_align2_gripper_pd_joint_pos`. `ManiSkill2_real2sim/.../pd_ee_pose.py:198-213`: `if frame == "base": target_pose = delta_pose * prev_ee_pose_at_base; elif frame == "ee": target_pose = prev_ee_pose_at_base * delta_pose; elif frame == "ee_align": # origin at ee but base rotation; target_pose = delta_pose * prev_ee_pose_at_base; target_pose.set_p(prev_ee_pose_at_base.p + delta_pos); elif frame == "ee_align2": cur_ee_pose_at_base = self.compute_fk(self.qpos); target_pose = (Pose(p=cur.p) * delta_pose * Pose(p=cur.p).inv()) * prev_ee_pose_at_base`. `maniskill2_evaluator.py:123`: `env.step(np.concatenate([action["world_vector"], action["rot_axangle"], action["gripper"]]))`. Confidence: high for the sim; as evidence for the real RT-1/Bridge frames: medium (indirect). |
| **ManiSkill 3** `PDEEPoseController` (`pd_ee_delta_pose`) | 6-D delta in [−1,1] (Panda ±0.1 m, ±0.1 rad); `use_delta=True`, `use_target=False` defaults | **root/base** default `"root_translation:root_aligned_body_rotation"` (space-frame); `body_translation` / `body_aligned_body_rotation` opt-in; GPU sim asserts the default only | current measured EE in root frame (`use_target=False`) or previous target | 3 dims parsed as **XYZ Euler** (`euler_angles_to_matrix(delta_rot, "XYZ")`), not rotvec | `mani_skill/agents/controllers/pd_ee_pose.py:256-262`: `if "root_aligned_body_rotation" in self.config.frame: q = quaternion_multiply(delta_pose.q, prev_ee_pose_at_base.q)`; `if "body_aligned_body_rotation" ...: q = quaternion_multiply(prev_ee_pose_at_base.q, delta_pose.q)`; `if "root_translation" ...: p = prev_ee_pose_at_base.p + delta_pos`; `if "body_translation" ...: p = ... + quaternion_apply(prev_ee_pose_at_base.q, delta_pose.p)`; `:293 ... = "root_translation:root_aligned_body_rotation"`. CAVEAT: `docs/source/user_guide/concepts/controllers.md` "Deep Dive" still says `R̄(t)=R(t)·e^{[a_R]×}` "in the end-effector frame" (stale ManiSkill 2 text, contradicts code). Confidence: high (code). |
| **ManiSkill 2** (legacy, `v0.5.3`) `pd_ee_delta_pose` — ManiSkill2 demo datasets | 6-D delta pose, `use_delta=True` | **tool** by default (`frame: str = "ee"`) — the one mainstream *default* tool-frame per-tick controller found | current measured EE (or previous target if `use_target`) | rotation vector | `v0.5.3 mani_skill2/agents/controllers/pd_ee_pose.py:131 frame: str = "ee"  # [base, ee]`, `:208 frame: str = "ee"  # [base, ee, ee_align]`; `delta_quat = Rotation.from_rotvec(delta_rot)...; if frame == "base": target_pose = delta_pose * prev_ee_pose_at_base; elif frame == "ee": target_pose = prev_ee_pose_at_base * delta_pose`. Panda `configs/panda/defaults.py:83-92` sets no `frame` → `"ee"`. Confidence: high. |
| **Isaac Lab** `DifferentialIKController` (`pose_rel`) and `OperationalSpaceController` (`pose_rel`) | 6-D delta `(dx,dy,dz, 3 axis-angle)`; `use_relative_mode=False` default (absolute 7-D) | **root/base** axes (space-frame) — controller is frame-agnostic, action term feeds root-frame EE pose; OSC: task-frame axes, identity by default | current measured EE (root frame), re-read every step | axis-angle (named `droll,dpitch,dyaw` but implemented as rotvec) | `isaaclab/utils/math.py:969-1006 apply_delta_pose`: `target_pos = source_pos + delta_pose[:, 0:3]`; `angle = torch.linalg.vector_norm(rot_actions, dim=1); axis = rot_actions / angle`; `# TODO: Check if this is the correct order for this multiplication.` `target_rot = quat_mul(rot_delta_quat, source_rot)`. `controllers/differential_ik.py`: ".. caution:: The controller does not assume anything about the frames of the current and desired end-effector pose". `envs/mdp/actions/task_space_actions.py _compute_frame_pose`: "Computes the pose of the target frame in the root frame." Tutorial `run_diff_ik.rst`: "The pose is specified in the robot's base frame." Confidence: high. |
| **MetaWorld** (Sawyer mocap) | 4-D `[dx,dy,dz, gripper]` in [−1,1] × 1/100 m; orientation fixed | **world** (mocap target) | previous mocap **target** (accumulates) | none | `metaworld/sawyer_xyz_env.py`: `action_scale: float = 1.0 / 100`; `set_xyz_action: new_mocap_pos = self.data.mocap_pos + pos_delta[None]; ... self.data.mocap_quat = np.array([1, 0, 1, 0])`. Confidence: high. |

---

## 3. Cross-cutting observations

### 3.1 Tally

| convention | as a *default* / stored form | as an opt-in |
|---|---|---|
| space-frame delta, base/world axes, left-multiply about the TCP origin (= MAVIS §3.2) | Bridge V2 robot stack; DROID stack (`cartesian_velocity`, `cartesian_position`); HIL-SERL/SERL; CALVIN/TACO `rel_actions_world`; robosuite OSC_POSE (robomimic, MimicGen, LIBERO, RoboCasa); RLBench delta `WORLD`; ManiSkill 3 default; Isaac Lab `pose_rel`; SIMPLER `ee_align`/`ee_align2` (RT-1, RT-2, Octo, OpenVLA evals); Diffusion Policy teleop integration; Octo/OpenVLA Bridge relabelling; MetaWorld (translation only); RT-1/RT-2 `world_vector` (inferred) | — |
| body/tool-frame relative transform, right-multiply (`T_tcp⁻¹ T_target`) | UMI; Isaac-GR00T `RELATIVE` EEF; legacy ManiSkill 2 `frame="ee"` | RLBench `RelativeFrame.EE`; ManiSkill 3 `body_translation` / `body_aligned_body_rotation`; robosuite `IK_POSE`; OpenVLA `droid_wristact_transform`; LeRobot `EEReferenceAndDelta` (rotation half only) |
| absolute EE pose | Diffusion Policy real robot; PerAct / RVT / 3D Diffuser Actor / Chain-of-Action keyposes; RLBench default; DROID paper policies (`cartesian_position` + rot6d); LeRobot EE example datasets; robomimic `actions_abs` | robosuite `input_type: absolute` |
| joint space (absolute, or delta vs chunk start) | ACT/ALOHA, Mobile ALOHA; π0/openpi own robots and DROID; GR00T GR-1; LeRobot default robots; DROID RLDS `action` (joint velocities); `lerobot/droid_1.0.1` | Octo/π0 fine-tune heads |
| deliberately unaligned across datasets | OXE / RT-1-X / RT-2-X; Octo; OpenVLA; π0-FAST on OXE; HPT | — |

Both researcher threads that covered the VLA/dataset side and the sim side
arrived at the same tally independently; the only mild disagreement was on
GR00T's paper-level frame statement (one thread read App. E.2 from the PDF,
the other could not fetch it) — the code-level finding is the same.

### 3.2 Why the two camps exist

The space-frame camp is *per-tick delta* control: a teleop device or policy
emits a small increment every 3–15 Hz step, and the controller adds it to
whatever pose the arm is at (or was last commanded to). Base axes are natural
there because the teleop device (SpaceMouse, VR controller after
`global_to_env_mat`, keyboard) lives in a fixed frame — DROID
`oculus_controller.py:104`: `rot_mat = self.global_to_env_mat @ self.vr_to_global_mat @ rot_mat`,
`:143-151 pos_action = target_pos_offset - robot_pos_offset; quat_action = quat_diff(target_quat_offset, robot_quat_offset)`.

The body-frame camp is *chunk-relative trajectory* prediction: UMI predicts a
horizon of poses relative to **one** anchor (the pose at t₀), which makes the
representation invariant to where the base sits and — crucially for UMI — puts
the action in the frame of the wrist camera that is rigidly attached to the
gripper. UMI's Fig. 6 argues against per-step deltas because they accumulate
error; GR00T inherits the representation and warns it "might suffer from
drifting" (`getting_started/data_config.md`). The two camps are therefore not
really competing answers to the same question: one is about how to integrate
tick-level commands, the other about how to parametrise a predicted trajectory.

### 3.3 Anchor: measured pose vs previous commanded target

- Measured-pose anchoring (ours): DROID (`robot_state["cartesian_position"]`
  every 15 Hz step), HIL-SERL (`self.currpos`, refreshed by
  `_update_currpos()` before each step), robosuite default
  (`goal_update_mode="achieved"`), ManiSkill (`use_target=False`), Isaac Lab
  (EE pose re-read from sim), RLBench (`get_tip().get_pose()`), UMI/GR00T
  (latest observed pose as chunk anchor), and the *dataset* form of Bridge as
  used by Octo/OpenVLA (`state[1:] - state[:-1]`).
- Target anchoring: Bridge's robot loop (`_next_qpos: delta.dot(get_target_state())`;
  the alternative `resetqpos_after_every_step` is commented as "can cause
  accumulating errors"), SIMPLER's WidowX replay (`use_target=True`), MetaWorld
  mocap, Diffusion Policy's SpaceMouse teleop, robosuite `goal_update_mode="desired"`.
- Consequence: a dataset anchored on the *measured* pose can be converted to
  every other representation exactly, because the anchor is observable and
  stored. A target-anchored dataset cannot be re-anchored without the commanded
  target stream (DROID stores it as `action_dict.cartesian_position`; Bridge
  does not, which is why Octo/OpenVLA relabel from state).

### 3.4 Rotation parametrisation

- rpy Euler *differences* (RT-1 `rotation_delta`, Bridge, DROID `cartesian_*`,
  CALVIN): a plain vector difference of Euler triples is only a first-order
  approximation of a rotation delta, and it is not even an exact space-frame
  rotation for finite steps. DROID's `add_angles` avoids this by converting to
  scipy rotations and multiplying; Octo/OpenVLA's Bridge relabel
  (`state[1:, :6] - state[:-1, :6]`) does not.
- rotation vector / axis-angle (HIL-SERL, robosuite OSC, Isaac Lab, ManiSkill 2,
  SIMPLER boundary, GR00T paper, LeRobot `ee.w*`): exact, singularity-free for
  small steps — our choice (`quat_to_rotvec`).
- unit quaternion (RLBench), rot6d (UMI, DROID policy learning, GR00T
  `XYZ_ROT6D`, OpenVLA `EEF_R6`): used where continuity for regression matters.
- Two implementation surprises: ManiSkill 3 parses its 3 rotation dims as XYZ
  Euler (`euler_angles_to_matrix(delta_rot, "XYZ")`) while its docs say
  axis-angle; Isaac Lab names the dims `droll,dpitch,dyaw` but implements a
  rotation vector, with a `# TODO: Check if this is the correct order` next to
  the left-multiply.

---

## 4. What this means for MAVIS v2

### 4.1 Where §3.2–3.3 stand relative to the field

| aspect | MAVIS 10-frames §3.2–3.3, §6 | field |
|---|---|---|
| composition | `p' = p + δp`, `q' = quat_mul(rotvec_to_quat(δr), q)` — `se3.py:237-238 integrate_twist`: `dq = rotvec_to_quat(tw.w * dt); return Pose(p.position + tw.v * dt, quat_mul(dq, p.orientation))` | identical to HIL-SERL, DROID `add_poses/add_angles`, robosuite `set_goal_orientation`, RLBench `calculate_delta_pose`, ManiSkill 3 default, Isaac Lab `apply_delta_pose`, SIMPLER `ee_align`, Bridge `action2transform_local` |
| axes | per-arm recording frame, `arm_base` default; `world`/`camera:<k>` selectable, converted by rotating the delta (§3.3) | base (DROID, HIL-SERL, robosuite v1.5, ManiSkill 3, Isaac Lab, SIMPLER) or world (Bridge, CALVIN, robosuite v1.4, RLBench) — for fixed bases these differ by one constant rotation, exactly §3.3's `R(q_W_Bi)`. OpenVLA's base→wrist code is the same conjugation. |
| anchor | current **measured** TCP (`policy_runner.py:190`: "``target = measured ⊕ clamp(Δ)`` -> IK -> q") | matches DROID, HIL-SERL, robosuite/ManiSkill/Isaac Lab/RLBench defaults, and relabelled Bridge; differs from Bridge's robot loop / SIMPLER WidowX (target-anchored) |
| rotation param | rotvec | matches HIL-SERL, robosuite, Isaac Lab, GR00T paper; differs from the rpy-difference datasets (RT-1, Bridge, DROID raw, CALVIN) |
| gripper | absolute open fraction | matches Octo/OpenVLA (+1 open), DROID, GR00T (`ABSOLUTE` gripper), openpi ("Gripper dimensions will remain in absolute values") |
| stored form | the **executed** delta, post-twin-gate, post-clamp | Bridge/DROID store the commanded delta; Octo/OpenVLA relabel to what was reached — ours is the "reached" flavour by construction |

Nothing in the survey argues for changing §3.2. The one convention we do *not*
match natively — UMI/GR00T chunk-relative body-frame transforms — is derivable
(§4.2) and is tied to a different policy class (chunked trajectory prediction)
than the per-tick `delta_ee` that 12-dagger needs for jump-free handovers.

### 4.2 Recommendation: keep §3.2 canonical; derive everything else offline

**Store exactly one action form: `delta_ee` as defined in §3.2/§6.** Do not add
a parallel tool-frame or absolute-target feature. All alternatives are exact
functions of what is already in each frame (`action` = `Δ_t`, and the measured
TCP pose `T_meas,t = (p_t, q_t)` in `observation.state[ee.*]`, same recording
frame):

1. **Absolute executed target** (for `abs_ee`-style consumers, robomimic
   `actions_abs`, DROID `cartesian_position`):
   `p_tgt,t = p_t + δp_t`, `q_tgt,t = rotvec_to_quat(δr_t) ⊗ q_t`.
2. **Tool/body-frame per-tick delta** (ManiSkill 2 `"ee"`, RLBench `EE`,
   OpenVLA wrist variant, LeRobot rotation semantics):
   `Δp_tool,t = R(q_t)ᵀ δp_t`, `Δq_body,t = q_t⁻¹ ⊗ rotvec_to_quat(δr_t) ⊗ q_t`
   (rotvec: `δr_body,t = R(q_t)ᵀ δr_t`).
3. **UMI / GR00T chunk-relative representation** (anchor `T_meas,t`, horizon k):
   `T_rel,t→t+k = T_meas,t⁻¹ · T_tgt,t+k` with `T_tgt,t+k` from item 1 — i.e.
   `p_rel = R(q_t)ᵀ (p_tgt,t+k − p_t)`, `q_rel = q_t⁻¹ ⊗ q_tgt,t+k`; convert to
   rot6d if the consumer wants `XYZ_ROT6D`. Use the *measured* poses at each
   t+k, not a chain-integrated `Δ`, so tracking error does not accumulate (this
   is UMI's own Fig. 6 argument and the reason the measured anchor matters).
4. **Other recording frame** (base ↔ world ↔ camera): §3.3 unchanged.
5. **rpy-difference export** for OXE-style consumers: compute
   `rpy(q_tgt,t) − rpy(q_t)` from item 1 and wrap; do *not* reinterpret `δr` as
   an rpy triple. State the convention in the dataset card (OXE never did, and
   that is the root of its "same action vector, different motion" warning).

Every one of these is lossless only because the anchor is the stored measured
pose. If we ever moved to target anchoring (Bridge style) we would have to add
the commanded target as a feature to keep this property.

### 4.3 Points to record in 10-frames (doc-level, no schema change)

- Say explicitly that §3.2 is the field-majority convention and name the peers
  (HIL-SERL, DROID, Bridge, robosuite/LIBERO, RLBench WORLD, ManiSkill 3, Isaac
  Lab), and that UMI/GR00T "relative" is the *other* convention with the
  conversion in §4.2 item 3. Today §3.2 only cites `integrate_twist` /
  `ActionAnchor.apply_delta`.
- Note the rotation-about-TCP-origin subtlety (SIMPLER `ee_align`, ManiSkill
  "root_aligned_body_rotation", Bridge `Teef · ΔT · Teef⁻¹`) so nobody
  "simplifies" the rule to a homogeneous left-multiply `ΔT · T`.
- Note that LeRobot's own `EEReferenceAndDelta` right-multiplies rotation; if
  the runtime ever routes through lerobot's EE processors, the rotation
  semantics must be converted (§1.3), or the translation and rotation halves
  will be in different frames.
- Note that when fine-tuning a pretrained VLA (OpenVLA/Octo/π0-FAST) our frame
  is simply one more un-aligned dataset frame — OXE never aligned frames, so
  there is no expected penalty beyond the usual, but the yaw of `arm_base`
  relative to the cameras is part of what the model must learn. For GR00T
  fine-tuning with an EEF head, convert to `RELATIVE` via §4.2 item 3 and check
  its rotation convention (`DROID_EEF_ROTATION_CORRECT` shows GR00T expects a
  particular tool-axis convention, "egocentric TFG").

---

## 5. Open questions

1. **Wrist-camera-egocentric policies on the grip arm.** UMI's reason for
   tool-frame actions is that the wrist camera is rigid to the tool. For a
   policy that sees *only* the grip arm's wrist camera, a tool-frame (or
   `camera:<wrist>` frame) action space might generalise better than
   `arm_base`. Our design already allows `camera:<k>` recording frames, but a
   wrist camera moves with the arm, so its extrinsics are per-frame, not
   per-session — §2.3/§5 assume static cameras. Whether that is worth
   supporting is an empirical question; §4.2 item 2/3 lets us try it offline
   from base-frame data without re-recording.
2. **Timing of the anchor sample.** §4.2's losslessness assumes the `ee.*`
   pose stored at dataset frame t is the *same* sample the runtime anchored
   `Δ_t` on. The 100 Hz loop interpolates between dataset frames (§6); the
   recorder must snapshot the anchor pose, not a later servo sample, or the
   derived absolute/tool-frame quantities pick up one tick of tracking error.
   Worth a unit test alongside §3.5.
3. **Executed vs commanded delta.** We store the post-clamp executed delta. For
   DAgger this is the right label (12-dagger §4). For UMI-style
   chunk-relative training, the *commanded* trajectory may be the better label
   when the twin gate clipped the human; we currently cannot distinguish the two
   after the fact unless `FrameAnnotations` keeps the pre-clamp command.
4. **RT-1 / RT-2 frame remains undocumented.** The best evidence that Google
   robot `world_vector` deltas are base-axis is SIMPLER's system-identified
   `ee_align` controller; the RT-1 paper, RT-2 paper and the OXE spreadsheet
   never say. If we ever co-train with `fractal20220817_data`, treat its frame
   as unverified.
5. **GR00T N1 paper vs repo.** App. E.2 ("axis-angle", min-max normalisation)
   was read from the PDF by one researcher but could not be fetched by the
   other; the tool-frame `RELATIVE` finding is from the 2026 repo and may
   post-date the N1 paper. Re-check before relying on it.
6. **Simulator doc drift.** ManiSkill 3's docs still describe the ManiSkill 2
   tool-frame rule; Isaac Lab's `apply_delta_pose` carries a "check the order"
   TODO. If we benchmark against either, verify the installed version's code,
   not the docs.
7. **robosuite base yaw.** Whether robosuite single-arm envs place the robot
   base with non-identity yaw (which would make v1.4 "world" and v1.5 "base"
   LIBERO deltas differ by that yaw) was not checked.
8. **Diffusion Policy real-robot frame.** The base-frame claim rests on UR
   `servoL` semantics and the paper's truncated Appendix D; not re-verified.

---

## Appendix — verification log

Spot-checked on 2026-09-04 by re-fetching the raw files and grepping the quoted
lines: `hil-serl franka_env.py:215-227`; `bridge_data_robot transformation_utils.py:142-158`
and `robot_base_env.py:182-185`; `droid transformations.py:34-70`;
`universal_manipulation_interface pose_repr_util.py:51-104` and `umi.yaml:87-89`;
`robosuite v1.4.1 control_utils.py:134-177` and `main osc.py:96-162, 326-341`;
`Isaac-GR00T pose.py:72, 662-678` and `action_chunking.py:651-655`;
`lerobot robot_kinematic_processor.py:51-149`; `openvla droid_utils.py:49-129`;
`RLBench arm_action_modes.py:30-232`; `ManiSkill main pd_ee_pose.py:33-293`;
`ManiSkill2_real2sim pd_ee_pose.py:57-213`; local `se3.py:229-238`,
`policy_runner.py:179-193`, `10-frames-and-data.md` §3.2–3.3 (L169-208), §6–7.
All matched the quotations above. Paper quotations are as reported by the two
research threads from arXiv HTML; pages noted as truncated (OpenVLA after App.
B.1.1, π0 appendix, DP App. D, GR00T App. E.2 in one thread, 3D Diffuser Actor
entirely) are marked UNVERIFIED where they matter.

No files other than this note were created or modified.
