# Research note: Dataset format for demo collection + DAgger (LeRobot v3 focus)

*Researched 2026-09-01 against `huggingface/lerobot` main (`dd25689`, pyproject version 0.6.2,
`CODEBASE_VERSION = "v3.0"`), source read from a local clone. All paths below refer to
`src/lerobot/...` inside that repo unless noted.*

---

## 1. TL;DR

- LeRobot's current on-disk format is **LeRobotDataset v3.0** (`lerobot.datasets.dataset_metadata.CODEBASE_VERSION = "v3.0"`, shipped since lerobot 0.4.0; v2.1 datasets must be converted with `lerobot.scripts.convert_dataset_v21_to_v30`). It is file-based: many episodes are concatenated into shared parquet + MP4 files; episode boundaries live purely in metadata.
- The write path is genuinely incremental and teleop-friendly: `LeRobotDataset.create(...)` → per-tick `add_frame(frame_dict)` (buffers in RAM, images to temp PNGs or a streaming video encoder) → `save_episode()` or `clear_episode_buffer()` (discard) → `finalize()`. This maps 1:1 onto our episode-buffer/save/discard UX.
- Multi-arm is just a wider `action` / `observation.state` vector with per-dimension `names` (upstream bimanual robots use `left_*` / `right_*` name prefixes); multi-camera is one `observation.images.<camera>` feature per camera. A 2×xArm7 (+grippers, +rail) setup is simply a 16–18-dim action with descriptive names.
- Frame conventions (base-frame vs camera-frame actions) are **not modeled by LeRobot at all** — it stores opaque float vectors. Feature dicts in `info.json` accept arbitrary extra JSON keys (verified: real datasets carry extra `"fps"` keys per feature), so we can define our own `"info": {"frame": ...}` annotation per feature, and/or a per-frame categorical feature if the frame can change per episode.
- DAgger prior art exists **in LeRobot itself**: `lerobot-rollout --strategy.type=dagger` (`lerobot/rollout/strategies/dagger.py`) records a per-frame `intervention` feature `{"dtype": "bool", "shape": (1,), "names": None}`, with a 3-state HITL state machine (AUTONOMOUS/PAUSED/CORRECTING) and two recording modes (record-everything vs corrections-only). We should copy this feature name/shape verbatim for compatibility.
- **Recommendation: adopt LeRobotDataset v3 as the primary format** (write with the real `lerobot` library, not a reimplementation), with a small workspace-specific convention layer on top (frame metadata, intervention/policy-source flags, wall-clock timestamps). Keep ALOHA-HDF5 only as an optional export if a specific training codebase demands it.

---

## 2. LeRobotDataset v3.0 format

### 2.1 Directory layout

From the `LeRobotDataset` docstring and path templates in `lerobot/datasets/utils.py`:

```
<root>/                                  # default: $HF_LEROBOT_HOME/{repo_id} (~/.cache/huggingface/lerobot/...)
├── meta/
│   ├── info.json                        # schema, fps, counters, path templates
│   ├── stats.json                       # aggregated normalization stats
│   ├── tasks.parquet                    # task string -> task_index
│   └── episodes/
│       └── chunk-000/file-000.parquet   # per-episode metadata rows (many episodes per file)
├── data/
│   └── chunk-000/file-000.parquet       # frame rows; MANY episodes per parquet file
└── videos/
    └── observation.images.<camera>/
        └── chunk-000/file-000.mp4       # MANY episodes concatenated per mp4
```

Path templates (exact constants in `lerobot/datasets/utils.py`):

```python
DEFAULT_DATA_PATH     = "data/chunk-{chunk_index:03d}/file-{file_index:03d}.parquet"
DEFAULT_VIDEO_PATH    = "videos/{video_key}/chunk-{chunk_index:03d}/file-{file_index:03d}.mp4"
DEFAULT_EPISODES_PATH = "meta/episodes/chunk-{chunk_index:03d}/file-{file_index:03d}.parquet"
DEFAULT_TASKS_PATH    = "meta/tasks.parquet"
DEFAULT_IMAGE_PATH    = "images/{image_key}/episode-{episode_index:06d}/frame-{frame_index:06d}.png"  # temp staging / image datasets
DEFAULT_CHUNK_SIZE    = 1000   # max files per chunk dir
DEFAULT_DATA_FILE_SIZE_IN_MB  = 100   # parquet rollover threshold
DEFAULT_VIDEO_FILE_SIZE_IN_MB = 200   # mp4 rollover threshold
```

Files roll over to `file-001`, `file-002`, ... when the size threshold is reached (`update_chunk_file_indices`); after 1000 files a new `chunk-XXX` directory starts. Rollover thresholds are configurable via `LeRobotDataset.create(..., data_files_size_in_mb=, video_files_size_in_mb=)`.

### 2.2 `meta/info.json`

Typed as `lerobot.datasets.utils.DatasetInfo` (dataclass). Real example from the v3 dataset `lerobot/svla_so101_pickplace` (fetched from the Hub):

```json
{
  "codebase_version": "v3.0",
  "robot_type": "so100_follower",
  "total_episodes": 50,
  "total_frames": 11939,
  "total_tasks": 1,
  "chunks_size": 1000,
  "fps": 30,
  "splits": {"train": "0:50"},
  "data_path": "data/chunk-{chunk_index:03d}/file-{file_index:03d}.parquet",
  "video_path": "videos/{video_key}/chunk-{chunk_index:03d}/file-{file_index:03d}.mp4",
  "features": {
    "action": {
      "dtype": "float32", "shape": [6],
      "names": ["shoulder_pan.pos", "shoulder_lift.pos", "elbow_flex.pos",
                "wrist_flex.pos", "wrist_roll.pos", "gripper.pos"]
    },
    "observation.state": { "dtype": "float32", "shape": [6], "names": [/* same */] },
    "observation.images.up": {
      "dtype": "video", "shape": [480, 640, 3],
      "names": ["height", "width", "channels"],
      "info": {
        "video.height": 480, "video.width": 640, "video.codec": "av1",
        "video.pix_fmt": "yuv420p", "video.is_depth_map": false,
        "video.fps": 30, "video.channels": 3, "has_audio": false
      }
    },
    "timestamp":     {"dtype": "float32", "shape": [1], "names": null},
    "frame_index":   {"dtype": "int64",   "shape": [1], "names": null},
    "episode_index": {"dtype": "int64",   "shape": [1], "names": null},
    "index":         {"dtype": "int64",   "shape": [1], "names": null},
    "task_index":    {"dtype": "int64",   "shape": [1], "names": null}
  },
  "data_files_size_in_mb": 100,
  "video_files_size_in_mb": 500
}
```

Feature spec = `{"dtype", "shape", "names", optional "info"}`.
`dtype` ∈ numpy dtype strings (`float32`, `int64`, `bool`, ...) | `"string"` | `"image"` | `"video"` | `"language"`.
The five bookkeeping features (`timestamp`, `frame_index`, `episode_index`, `index`, `task_index`) come from `lerobot.utils.constants.DEFAULT_FEATURES` and are **auto-added** by `LeRobotDatasetMetadata.create` and auto-populated at write time — the caller must NOT put them in `add_frame` dicts (`validate_frame` rejects them as "extra features").

Two constraints worth knowing:
- Feature names must not contain `/` (`lerobot/utils/feature_utils.py::_validate_feature_names`). Dots are the namespace separator.
- Unknown **top-level** keys in `info.json` are dropped with a warning on load (`DatasetInfo.from_dict`), but arbitrary extra keys **inside a feature dict** (or the per-feature `"info"` sub-dict) round-trip fine — that's where custom metadata belongs.

### 2.3 Frame parquet schema

`data/*.parquet` holds one row per frame. Columns = all non-video features. Mapping to HF `datasets` types (`lerobot/datasets/feature_utils.py::get_hf_features_from_features`):

- `shape == (1,)` → `datasets.Value(dtype)` (stored as a scalar column, e.g. `timestamp`, `intervention`)
- 1-D shape `(N,)` → `datasets.Sequence(length=N, feature=Value(dtype))` (e.g. `action`, `observation.state`)
- 2-D..5-D → `Array2D..Array5D`
- `dtype == "image"` → `datasets.Image()` (PNG bytes embedded in parquet via `embed_images`)
- `dtype == "video"` → **not in parquet at all**; frames live only in the MP4s

Parquet files are written with an incremental `pyarrow.parquet.ParquetWriter` (snappy compression, dictionary encoding); each `save_episode()` appends a row group to the currently open file.

`timestamp` is synthesized as `frame_index / fps` inside `DatasetWriter.add_frame` — **wall-clock capture time is not stored**. The reader validates spacing against `fps ± tolerance_s` (default 1e-4 s). If we care about real capture jitter (we do, at ~100 Hz servo streaming), we must add our own feature, e.g. `"wallclock_ns": {"dtype": "int64", "shape": (1,), "names": None}`.

### 2.4 Episode indexing (`meta/episodes/*.parquet`)

One row per episode, written by `LeRobotDatasetMetadata._save_episode_metadata` (buffered, default flush every 10 episodes). Columns:

| column | meaning |
|---|---|
| `episode_index`, `tasks` (list[str]), `length` | identity |
| `dataset_from_index`, `dataset_to_index` | global frame-range [from, to) of the episode |
| `data/chunk_index`, `data/file_index` | which parquet shard holds the rows |
| `videos/<video_key>/chunk_index`, `.../file_index` | which mp4 shard holds the frames (per camera) |
| `videos/<video_key>/from_timestamp`, `.../to_timestamp` | time offset of this episode inside the concatenated mp4 |
| `meta/episodes/chunk_index`, `meta/episodes/file_index` | self-location of the metadata row |
| `stats/<feature>/<min\|max\|mean\|std\|count\|q01\|q10\|q50\|q90\|q99>` | flattened per-episode stats |

Frame lookup on read: row index → `episode_index` → episode row → video decode at `from_timestamp + frame.timestamp` (`dataset_reader.py::_query_videos`). Episode-level access from user code: `dataset.meta.episodes[i]["dataset_from_index"]` etc.

### 2.5 `meta/tasks.parquet` and `meta/stats.json`

- `tasks.parquet`: pandas DataFrame, index = task string, column `task_index`. New tasks are auto-registered per episode (`LeRobotDatasetMetadata.save_episode_tasks`). Every frame's `task_index` points into it (task-conditioned policies read this).
- `stats.json`: per-feature `{min, max, mean, std, count, q01, q10, q50, q90, q99}` aggregated across episodes (`lerobot/datasets/compute_stats.py`, `RunningQuantileStats`). Image/video stats are per-channel, normalized to [0,1], shape `(3,1,1)`. These stats drive policy input normalization (`make_pre_post_processors(..., dataset_stats=...)`), so they must be correct — recompute with `lerobot.datasets.dataset_tools.recompute_stats` after any surgery.

### 2.6 Video encoding

Defaults (`lerobot/configs/video.py`):

- RGB: `RGBEncoderConfig` → `vcodec="libsvtav1"` (AV1), `pix_fmt="yuv420p"`, `g=2` (keyframe every 2 frames → cheap random access), `crf=30`, backend PyAV. `vcodec="auto"` picks a HW encoder if present (`h264_nvenc`/`hevc_nvenc` etc. — relevant on our 2×RTX 4090).
- Depth: `DepthEncoderConfig` → `vcodec="hevc"`, `pix_fmt="gray12le"`, lossless x265, 12-bit log-quantized depth in `[depth_min=0.01, depth_max=10.0]` m; depth cameras are declared as `(H, W, 1)` shapes and flagged `info["is_depth_map"] = true`.
- Two encode paths:
  1. Default: `add_frame` dumps PNGs (optionally via `AsyncImageWriter` threads/processes: `image_writer_threads≈4/camera`), `save_episode` runs ffmpeg per camera (parallel across cameras via `ProcessPoolExecutor`).
  2. `streaming_encoding=True`: `StreamingVideoEncoder` encodes in real time during capture; `save_episode()` becomes near-instant. This is what `lerobot-record` recommends (`--dataset.streaming_encoding=true --dataset.encoder_threads=2`) and what a DAgger loop needs (no multi-second stall between episodes).
- New episodes are **concatenated onto the tail of the current mp4** (`concatenate_video_files`) until `video_files_size_in_mb` is exceeded, then a new file starts.

---

## 3. Incremental writing during teleop (episode buffer → save/discard)

### 3.1 Core API (`lerobot/datasets/lerobot_dataset.py`, `dataset_writer.py`)

```python
from lerobot.datasets import LeRobotDataset

ds = LeRobotDataset.create(
    repo_id="apollo/xarm7_dual_task1",
    fps=30,
    features=features,                # dict as in §2.2, WITHOUT the 5 default features
    root="/data/lerobot/xarm7_dual_task1",   # else $HF_LEROBOT_HOME/{repo_id}
    robot_type="xarm7_dual_rail",     # free-form string
    use_videos=True,
    streaming_encoding=True,          # real-time mp4 encoding
    image_writer_threads=4 * num_cameras,  # only used for the PNG path
)

# per control tick (all values numpy or torch; torch is converted):
ds.add_frame({
    "observation.state": state_vec,           # float32 (16,)
    "observation.images.front": rgb_hwc,      # uint8 (H,W,3)
    "action": action_vec,                     # float32 (16,)
    "task": "stack the red cube on the blue cube",   # REQUIRED string, per frame
})

ds.save_episode()          # encode videos, append parquet row-group, update meta/stats
# or, to discard the in-progress episode (operator hit "discard"):
ds.clear_episode_buffer()  # cancels streaming encoder + deletes temp frames

ds.finalize()              # MUST be called at end: closes ParquetWriters, writes footers
ds.push_to_hub()           # optional
```

Key mechanics (from `DatasetWriter`):
- `add_frame` is validated against the features dict (`validate_frame`: exact key set + dtype/shape check); it appends non-image values to an in-RAM `episode_buffer`, writes camera frames to temp PNGs or feeds the streaming encoder, and auto-appends `frame_index`/`timestamp`/`task`.
- Nothing hits the final dataset until `save_episode()` — discard is free. `has_pending_frames()` tells you if a buffer is open.
- `save_episode()` computes per-episode stats, appends to the shared parquet via a held-open `ParquetWriter`, encodes/concatenates videos, updates `meta/episodes`, `info.json` counters, `tasks.parquet`, `stats.json`.
- **`finalize()` is mandatory** — without it parquet footers are missing and the dataset is unreadable. `LeRobotDataset.resume(repo_id, root=...)` re-opens an existing dataset for appending (root is required; it refuses to write into the hub snapshot cache). Reading while a writer is open raises (`"Cannot read from a dataset that is being recorded. Call finalize() first"`), i.e. one process should own writing.
- `VideoEncodingManager` (context manager used by `lerobot-record` and the DAgger strategy) guarantees pending batch/streaming encodes are flushed on exit/crash.

### 3.2 `lerobot-record` as reference loop

`lerobot/scripts/lerobot_record.py::record_loop` (paced by `CycleTimer` at `fps`):

1. `obs = robot.get_observation()` → `robot_observation_processor(obs)`
2. `observation_frame = build_dataset_frame(dataset.features, obs_processed, prefix="observation")`
3. `act = teleop.get_action()` → `teleop_action_processor` → `robot_action_processor` → `robot.send_action(...)`
4. `action_frame = build_dataset_frame(dataset.features, action_values, prefix="action")`
5. `dataset.add_frame({**observation_frame, **action_frame, "task": single_task})`

Episode flow: keyboard events → `exit_early` ends the episode, `rerecord_episode` triggers `dataset.clear_episode_buffer()` and a redo, otherwise `dataset.save_episode()`; an untimed "reset the environment" teleop phase runs between episodes without recording. The whole session sits in `with VideoEncodingManager(dataset):` and ends with `dataset.finalize()`.

Helper functions worth reusing directly (`lerobot/utils/feature_utils.py`):
- `hw_to_dataset_features(hw_features, prefix, use_video)` — builds the features dict from a flat `{name: float | (H,W,C)}` map; float entries are packed into one `observation.state`/`action` vector feature (names = the keys), tuple entries become `observation.images.<key>`.
- `build_dataset_frame(ds_features, values, prefix)` — inverse: packs a flat value dict into the vector + image features for `add_frame`.
- `combine_feature_dicts(*dicts)` — merges vector features (concatenates `names`, recomputes shape) — this is how multi-arm action vectors get assembled.

### 3.3 Rate considerations (100 Hz teleop vs dataset fps)

- The dataset `fps` is a single int for **all** features; timestamps are synthesized. Recording at 100 Hz is legal (`fps=100`) but cameras won't deliver 100 fps, and LeRobot has no per-feature rate in v3 (frames are row-aligned).
- LeRobot's own answer (DAgger docs): run control at `fps × interpolation_multiplier` while recording at `fps` — e.g. record 25–30 Hz, servo-stream at 100 Hz via interpolation. For us: keep the 100 Hz cartesian servo loop in the runtime, subsample/snapshot at 20–30 Hz into the dataset, and optionally store our own `wallclock_ns` feature for diagnostics.

---

## 4. Multi-arm and multi-camera representation

There is no structural "arm" concept — everything is naming conventions over flat vectors:

- **State/action**: one `observation.state` and one `action` feature; per-dimension semantics only via `names`. Upstream bimanual robots (`lerobot/robots/bi_so_follower`, `bi_openarm_follower`, via `BimanualMixin`) prefix motor keys with `left_` / `right_`, producing e.g. `names = ["left_shoulder_pan.pos", ..., "left_gripper.pos", "right_shoulder_pan.pos", ..., "right_gripper.pos"]` (12-dim for bi-SO100; ALOHA-style datasets are 14-dim the same way).
- **Cameras**: one feature per camera `observation.images.<camera>`; bimanual robots prefix per-arm cameras (`observation.images.left_wrist`, `right_wrist`) and keep shared cameras unprefixed (`top`, `front`). Policies match on these exact keys (a `--rename_map` exists in rollout for mismatches).
- **EE-space actions**: the SO-100 EE example (`examples/so100_to_so100_EE`, `lerobot/robots/so_follower/robot_kinematic_processor.py`) uses action names `ee.x, ee.y, ee.z, ee.wx, ee.wy, ee.wz, ee.gripper_pos` — a reasonable convention to extend as `left_ee.x`, ....
- Scalar per-frame extras use dotted namespaces: `next.reward`, `next.done`, `complementary_info.<name>` (see HIL-SERL recorder in `lerobot/rl/gym_manipulator.py`).

Proposed schema for our stack (2 arms on rail, joint-space actions; adjust dim for cartesian):

```python
ARM = [f"joint{i}.pos" for i in range(1, 8)] + ["gripper.pos"]
features = {
    "action": {
        "dtype": "float32", "shape": (18,),
        "names": [f"left_{n}" for n in ARM] + ["left_rail.pos"]
               + [f"right_{n}" for n in ARM] + ["right_rail.pos"],
    },
    "observation.state": { ... same names ... },
    "observation.images.front":       {"dtype": "video", "shape": (480, 640, 3), "names": ["height", "width", "channels"]},
    "observation.images.left_wrist":  {"dtype": "video", "shape": (480, 640, 3), "names": ["height", "width", "channels"]},
    "observation.images.right_wrist": {"dtype": "video", "shape": (480, 640, 3), "names": ["height", "width", "channels"]},
}
```

For a 1-arm session the same code emits a 9-dim vector — dataset schemas are per-repo, so 1-arm and 3-arm sessions are **separate datasets** (LeRobot cannot mix shapes within one repo; `MultiLeRobotDataset` / `lerobot.datasets.dataset_tools.merge_datasets` require compatible features for merging).

---

## 5. Frame conventions (base frame vs camera frame)

LeRobot does **not** model coordinate frames anywhere: `action` is an opaque float vector; the only semantics are `names`, `robot_type`, and free-form per-feature `info`. Two places to encode our per-arm frame choice:

1. **Static per-dataset (preferred)** — extra keys inside the feature dict survive round-trips (upstream itself stores extra keys like `fps` and `info.video.*` there; only unknown *top-level* `info.json` keys are dropped by `DatasetInfo.from_dict`):

```python
features["action"]["info"] = {
    "action_space": "joint_position",         # or "ee_pose_delta", ...
    "frames": {"left": "base", "right": "camera:front"},   # our convention, ours to define
    "rail": {"axis": "y", "travel_m": 0.65},
}
```

2. **Per-frame, if the frame can differ per episode/arm dynamically** — a small categorical feature, mirroring the `intervention` pattern:

```python
features["action_frame_id"] = {"dtype": "int8", "shape": (2,), "names": ["left", "right"]}
# 0 = base/world, 1 = camera:front, ... ; mapping documented in features["action_frame_id"]["info"]
```

Caveat: nothing in LeRobot's training stack will interpret this — normalization stats are computed over the raw vectors regardless of frame. Mixing frames **within one dataset's `action` feature is statistically toxic** (one normalization applies to all rows), so the sane design is: frame choice fixed per dataset (encode in feature `info` + repo naming, e.g. `..._camframe`), and convert at collection time in the runtime rather than storing heterogeneous frames.

---

## 6. DAgger / intervention marking

### 6.1 Upstream implementation (use as blueprint)

`lerobot-rollout --strategy.type=dagger` (`lerobot/rollout/strategies/dagger.py` + `lerobot/rollout/context.py`, docs `docs/source/hil_data_collection.mdx`):

- Feature declaration (`rollout/context.py`, added only for DAgger runs):

```python
dataset_features["intervention"] = {"dtype": "bool", "shape": (1,), "names": None}
```

- Per-frame tagging: human-correction frames get `"intervention": np.array([True], dtype=bool)`, autonomous frames `False`. That is the entire intervention mask — a plain per-frame bool column in the parquet, filterable at training time (e.g. via `LeRobotDataset(..., episode_filter=...)` or dataframe ops on the parquet).
- State machine: `AUTONOMOUS --pause--> PAUSED --correction--> CORRECTING --correction--> PAUSED --pause--> AUTONOMOUS`, driven by keyboard or USB foot pedal (`DAggerKeyboardConfig` / `DAggerPedalConfig`). On AUTONOMOUS→PAUSED the inference engine pauses and the robot holds; smooth handover moves leader-to-follower (actuated teleop) or slides follower-to-teleop pose.
- Two recording modes (`record_autonomous` flag):
  - `True` ("sentry"): record everything continuously; episodes are auto-rotated by a duration derived from the target video file size; corrections tagged `intervention=True`.
  - `False`: only correction windows are recorded; **each correction = one episode**; background `push_to_hub` on demand.
- Rate decoupling: `--interpolation_multiplier=N` → control at `fps×N`, policy inference + recording at `fps` (recorded corrections are strided by N so the dataset keeps its declared fps).
- Fine-tuning: upstream just trains on demos + HIL datasets combined; there is **no automatic weighting of intervention frames** — the mask is there for whatever sampling/weighting scheme we implement.
- Related conventions from HIL-SERL (`lerobot/rl/gym_manipulator.py`): per-frame `next.reward` (float32, (1,)), `next.done` (bool, (1,)), `complementary_info.discrete_penalty`; interventions travel through processor pipelines as `TeleopEvents.IS_INTERVENTION` in `complementary_data` (`lerobot/processor/hil_processor.py`) but are persisted only via the recorded action (the teleop action replaces the policy action in the saved frame).
- Lineage cited by upstream docs: DAgger (Ross 2011), **HG-DAgger** (Kelly 2019 — the human-gated pause/takeover/return loop is explicitly modeled on it), RaC (Hu 2025), π0.6/RECAP.

### 6.2 What we should store (superset, still LeRobot-compatible)

```python
features["intervention"] = {"dtype": "bool", "shape": (1,), "names": None}   # exact upstream name
features["action_source"] = {"dtype": "int8", "shape": (1,), "names": None,
    "info": {"labels": {"0": "policy", "1": "human_teleop", "2": "reset_planner"}}}
features["policy_action"] = {"dtype": "float32", "shape": (18,), "names": [...]}  # optional:
# what the policy WOULD have done during human takeover — upstream does NOT store this,
# but HG-DAgger-style gating losses / intervention-prediction need it and it is cheap to log.
```

Everything else (episode boundary on takeover, weighting) is a training-side choice, not a format concern. Datasets from different modes (plain teleop without `intervention` column vs DAgger with it) have different schemas; `merge_datasets` requires compatible features, so either add the columns to all recorded datasets from day one (recommended: always write `intervention=False` in plain teleop), or backfill later with `lerobot.datasets.dataset_tools.add_features` (copies the dataset once, can add constant or computed columns).

---

## 7. Alternative: ALOHA-style HDF5

Format (verified against `tonyzhaozh/act` `record_sim_episodes.py`; the real-robot ALOHA/mobile-ALOHA recorder is the same plus effort/compression):

```
episode_{idx}.hdf5
├── attrs: sim (bool), compress (bool, real-robot recorder)
├── /observations/qpos   (T, 14) float64
├── /observations/qvel   (T, 14) float64
├── /observations/effort (T, 14)            # real-robot recorder
├── /observations/images/{cam} (T, 480, 640, 3) uint8, chunks=(1,480,640,3)
│                                            # or (T, padded_len) JPEG bytes + /compress_len when compress=True
└── /action              (T, 14) float64
```

| | LeRobot v3 | ALOHA HDF5 |
|---|---|---|
| Write path | incremental, buffer→save/discard built in | trivial (one file per episode, dump arrays at end) |
| Image storage | AV1/HEVC video, ~50-100× smaller than raw; GPU-decodable | raw uint8 or per-frame JPEG; huge files (raw ≈ 1.6 GB/min/cam) |
| Episode granularity | metadata-indexed shared files; delete/split needs tooling (`lerobot-edit-dataset`) | 1 file = 1 episode; delete = `rm` |
| Random access cost | video seek (mitigated by `g=2` keyframes) | O(1) into HDF5 chunk |
| Schema/metadata | typed features, names, stats, tasks, versioning | none (implicit, per-codebase) |
| Ecosystem | HF Hub streaming/viz, `lerobot-train` for ACT/DP/pi0/SmolVLA, processors, `StreamingLeRobotDataset`, merge/split/edit tools, experimental Lance backend | ACT/original ALOHA repos only; every consumer writes a custom loader |
| Multi-arm / multi-cam | native (names + per-camera features) | ad-hoc |
| Intervention masks | plain bool column (upstream precedent) | ad-hoc extra dataset |
| Risks | format still evolving (v2.1→v3.0 was breaking); writer library is heavyweight | you own the whole toolchain; storage cost |

**Recommendation: LeRobot v3 as the single primary format.** Our modes (teleop collection, DAgger with intervention masks, per-task episode datasets, HF-ecosystem training) map directly onto it, the incremental writer matches our UX, and the DAgger convention already exists upstream. An ALOHA-HDF5 *exporter* (iterate `LeRobotDataset`, decode frames, write per-episode HDF5) is ~100 lines if ever needed; the reverse migration is what upstream's porting examples do (`examples/port_datasets/port_droid.py` is the canonical create/add_frame/save_episode porting loop).

---

## 8. Concrete guidance for apollo-xarm7

1. **Depend on `lerobot` (≥0.6) in the data-collection package** and use `LeRobotDataset.create/resume/add_frame/save_episode/clear_episode_buffer/finalize` directly — do not reimplement the writer (parquet rollover, video concat, stats, and metadata buffering are subtle). Pin the version; the format has a history of breaking majors.
2. One dataset repo per (task × arm-count × action-space/frame convention). Stamp session names (upstream appends `_%Y%m%d_%H%M%S` via `DatasetRecordConfig.stamp_repo_id`) and merge with `lerobot.datasets.dataset_tools.merge_datasets` later.
3. Fixed schema fields for every recording mode: `observation.state` + `action` (names as §4), one `observation.images.*` per camera stream, `intervention` (bool), `action_source` (int8), `wallclock_ns` (int64). DAgger adds nothing new structurally — same schema, different writer of `action`.
4. Record at 20–30 fps; keep the 100 Hz servo loop out of the dataset (interpolate, as upstream DAgger does with `interpolation_multiplier`). Use `streaming_encoding=True` with `rgb_encoder.vcodec="auto"` (NVENC on the 4090s) so `save_episode()` doesn't stall the UI between episodes.
5. Frame conventions: fix per dataset, encode in `features["action"]["info"]` (+ repo naming); convert camera-frame teleop commands to the dataset's declared frame at collection time in the runtime.
6. Sim vs real: same schema; distinguish via `robot_type` (e.g. `xarm7_dual_rail` vs `xarm7_dual_rail_mujoco`) and a `sim` tag on the Hub; that keeps sim/real datasets mergeable for co-training.
7. The writer is single-process: give the dataset-writer its own process/service in the runtime; teleop/DAgger loops feed it frames over the internal bus (mirrors `record_loop`'s single-threaded `add_frame`).

### Key API index

| Purpose | Symbol |
|---|---|
| create/append/write | `lerobot.datasets.LeRobotDataset.create / .resume / .add_frame / .save_episode / .clear_episode_buffer / .finalize / .push_to_hub` |
| writer internals | `lerobot.datasets.dataset_writer.DatasetWriter`, `lerobot.datasets.image_writer.AsyncImageWriter`, `lerobot.datasets.video_utils.StreamingVideoEncoder`, `lerobot.datasets.VideoEncodingManager` |
| metadata | `lerobot.datasets.dataset_metadata.LeRobotDatasetMetadata` (`.info/.stats/.tasks/.episodes`), `CODEBASE_VERSION` |
| feature helpers | `lerobot.utils.feature_utils.hw_to_dataset_features / build_dataset_frame / combine_feature_dicts`, `lerobot.utils.constants.{OBS_STATE, OBS_IMAGES, ACTION, DEFAULT_FEATURES}` |
| encoders | `lerobot.configs.video.{RGBEncoderConfig, DepthEncoderConfig}` |
| DAgger | `lerobot.rollout.strategies.dagger.DAggerStrategy`, `lerobot.rollout.configs.DAggerStrategyConfig` (CLI: `lerobot-rollout --strategy.type=dagger`) |
| dataset surgery | `lerobot.datasets.dataset_tools.{delete_episodes, split_dataset, merge_datasets, add_features, remove_feature, modify_tasks, recompute_stats}` (CLI: `lerobot-edit-dataset`) |
| loading/training | `lerobot.datasets.LeRobotDataset(repo_id, delta_timestamps=..., episode_filter=...)`, `lerobot.datasets.streaming_dataset.StreamingLeRobotDataset` |
