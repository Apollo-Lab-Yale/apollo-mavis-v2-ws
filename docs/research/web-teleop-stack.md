# Web UI + Transport Stack for Teleop/Inference (apollo-mavis-v2-ui + runtime server)

Research note, 2026-09-01. Scope: control plane (keyboard streaming), video transport,
MuJoCo-to-browser rendering, frontend patterns, camera abstraction, and overall server
architecture for the apollo-mavis-v2 stack (1–3 real xArm7 + MuJoCo sim/digital twin,
localhost/LAN, single operator, Ubuntu 22.04, 2x RTX 4090).

Sources read: FastAPI WebSocket docs, uvicorn `Config` source, aiortc source +
`examples/webcam` (cloned to `/tmp/aiortc`), LeRobot camera/teleop source (cloned to
`/tmp/lerobot`), MuJoCo Python renderer source (`mujoco/rendering/classic/renderer.py`),
MuJoCo EGL backend source, official MuJoCo WASM bindings README (`wasm/README.md`),
`zalo/mujoco_wasm`, MDN `KeyboardEvent.code`, `react-hotkeys-hook`.

---

## TL;DR recommendations

| Concern | Recommendation |
|---|---|
| Control plane | One FastAPI app; **one control WebSocket** carrying key-transition events **plus a 20 Hz full-key-state heartbeat** (hybrid), JSON messages; server-side watchdog zeroes velocity if heartbeat stops |
| Video | **JPEG frames over WebSocket** (binary), one WS per stream or one multiplexed WS; keep a plain **MJPEG-over-HTTP** endpoint per stream as a zero-dependency debug view. Skip WebRTC/aiortc for now |
| MuJoCo → browser | **Server-side offscreen render** (`mujoco.Renderer`, `MUJOCO_GL=egl`) streamed exactly like a camera. Do not use MuJoCo WASM (state would fork from the server-authoritative sim) |
| Frontend | React 18 + Vite + TypeScript; bespoke `useKeyState` hook on `KeyboardEvent.code` (not `key`), explicit "capture mode" component, `preventDefault` on Tab/Space/arrows, release-all on `blur`/`visibilitychange` |
| Cameras | LeRobot-style `Camera` ABC (`connect / read / async_read / read_latest / disconnect / find_cameras`) with `OpenCVCamera` (V4L2) and `RealSenseCamera` (pyrealsense2) implementations; identify by `/dev/v4l/by-id/` path or RealSense serial |
| Server shape | Single FastAPI app: REST for config/session lifecycle, WS for control + telemetry + video, SPA served as static files (or Vite dev proxy in dev). This is sane; alternatives noted below |

---

## 1. Control plane: FastAPI + WebSocket

### 1.1 FastAPI WebSocket API (exact names)

- Decorator: `@app.websocket("/ws/control")`
- Connection object: `fastapi.WebSocket` (re-export of `starlette.websockets.WebSocket`)
- Methods: `await ws.accept()`, `await ws.receive_json()` / `send_json()`,
  `receive_text()` / `send_text()`, `receive_bytes()` / `send_bytes()`
- Disconnect: `receive_*` raises `fastapi.WebSocketDisconnect`; server-initiated close via
  `fastapi.WebSocketException(code=status.WS_1008_POLICY_VIOLATION)`
- `Depends`/`Query`/`Cookie` work on WS endpoints like on HTTP endpoints.

uvicorn WS-relevant settings (from `uvicorn/config.py`, defaults):
`ws="auto"`, `ws_max_size=16*1024*1024`, `ws_max_queue=32`,
`ws_ping_interval=20.0`, `ws_ping_timeout=20.0`, `ws_per_message_deflate=True`.

For a 100 Hz control channel **disable permessage-deflate** (compression adds CPU +
buffering for tiny messages that don't compress usefully):

```bash
uvicorn app:app --ws-per-message-deflate=False
# or uvicorn.run(app, ws_per_message_deflate=False)
```

### 1.2 Key events vs 50 Hz state vector — use a hybrid

Three candidate protocols for keyboard → server:

1. **Pure transitions** (`keydown`/`keyup` only): minimal traffic and minimal latency
   (an edge is sent the moment it happens), but a single lost/ignored `keyup` (tab
   switch, focus loss, GC pause, reconnect) leaves the robot moving forever. Not
   acceptable alone.
2. **Pure periodic state vector** (e.g. 50 Hz set-of-held-keys): self-healing (any stale
   state is overwritten ≤20 ms later) and doubles as a deadman heartbeat, but quantizes
   edge latency to the period.
3. **Hybrid (recommended)**: send a state message *immediately on any transition*, plus a
   periodic full-state heartbeat at 20–50 Hz while the tab has capture. The server only
   ever stores "current held-key set + last message time". Edges arrive with ~0 added
   latency; the heartbeat provides self-healing and the watchdog signal.

Message format (client → server), JSON is fine at this rate (a ~120-byte JSON parse is
microseconds; 50 Hz × ~120 B ≈ 6 KB/s):

```jsonc
// sent on every transition AND every 20-50ms while capturing
{
  "t": "keys",
  "seq": 1042,                 // monotonically increasing, for staleness rejection
  "ts": 1756711234.123,        // client wall clock (for latency measurement only)
  "held": ["KeyW", "KeyJ"],    // full set of currently-held movement keys (event.code values)
  "arm": 0,                    // active arm index (Tab cycles it client-side)
  "dagger": false              // Space held => human takeover
}
// discrete actions as separate one-shot events (never inferred from `held`)
{ "t": "action", "name": "episode_start" }
{ "t": "action", "name": "switch_arm", "arm": 1 }
```

Server side, the WS handler does **no motion itself** — it only updates shared state; the
100 Hz+ servo loop (separate `asyncio` task or thread) reads it each tick and converts the
held-key set into a cartesian twist:

```python
@app.websocket("/ws/control")
async def control_ws(ws: WebSocket):
    await ws.accept()
    session = runtime.acquire_controller(ws)   # enforce single writer, see 1.4
    try:
        while True:
            msg = await ws.receive_json()
            if msg["t"] == "keys":
                if msg["seq"] > session.last_seq:      # drop reordered/stale
                    session.last_seq = msg["seq"]
                    session.held = frozenset(msg["held"])
                    session.active_arm = msg["arm"]
                    session.last_rx = time.monotonic() # watchdog feed
            elif msg["t"] == "action":
                await runtime.dispatch_action(msg)
    except WebSocketDisconnect:
        runtime.release_controller(session)            # => immediate zero-twist

# in the 100Hz servo loop:
if time.monotonic() - session.last_rx > WATCHDOG_S:    # 0.15-0.25 s
    twist = ZERO
else:
    twist = keymap_to_twist(session.held)
```

Watchdog notes: 0.2 s covers heartbeat jitter at 20 Hz with margin; make the transition
back from watchdog-stop require a fresh all-keys-up state so the robot never "resumes"
motion by itself. The xArm servo layer should additionally ramp to zero rather than hard
stop.

### 1.3 Reconnect handling

Browsers' native `WebSocket` has no auto-reconnect. The `reconnecting-websocket` npm
package exists but a bespoke ~30-line wrapper is preferable (you need custom hooks into
capture state anyway):

```ts
function makeReconnectingWS(url: string, onMsg: (m: any) => void, onStatus: (s: "open"|"closed") => void) {
  let ws: WebSocket, backoff = 250;
  const connect = () => {
    ws = new WebSocket(url);
    ws.onopen = () => { backoff = 250; onStatus("open"); };
    ws.onmessage = (e) => onMsg(JSON.parse(e.data));
    ws.onclose = () => {
      onStatus("closed");
      setTimeout(connect, backoff + Math.random() * backoff); // jitter
      backoff = Math.min(backoff * 2, 5000);
    };
    ws.onerror = () => ws.close();
  };
  connect();
  return { send: (m: unknown) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify(m)) };
}
```

Protocol rules that make reconnects safe:

- **Server**: controller disconnect ⇒ immediately zero twist, drop held-key state, mark
  session "controller absent". Never buffer control messages across connections.
- **Client**: on reconnect, do a REST `GET /api/session` (or a `hello` WS exchange) to
  re-sync mode/arm/episode state, then resume heartbeats *from an all-keys-up state* —
  never replay the pre-disconnect held set.
- Use a **session epoch/id**: server includes `epoch` in its hello; if the runtime
  restarted mid-session, the client detects the epoch change and returns to the landing
  page instead of assuming state.
- UI must show a prominent "CONTROL LINK DOWN" banner while disconnected (motion is
  frozen by the watchdog anyway, but the operator needs to know).

### 1.4 Single-writer control

Only one control WS may command motion. Pattern: `runtime.acquire_controller()` rejects a
second connection with WS close code `1008` (or accepts it as read-only "observer" and
offers explicit takeover). This also cleanly handles the duplicate-tab footgun.

### 1.5 Telemetry channel

Separate WS (`/ws/telemetry`) pushed by the server at ~20–30 Hz: joint states, EE poses,
rail position, collision warnings from the digital twin
(`{"t":"collision","pairs":[["arm0/link5","arm1/link3"]],"min_dist":0.012,"severity":"warn"}`),
episode/recording status, DAgger mode, controller-connected flag. Keeping it separate
from `/ws/control` means a slow render/telemetry consumer can never back-pressure the
control path, and observers can subscribe without acquiring control.

---

## 2. Video transport: MJPEG vs WS-JPEG vs WebRTC

Target: 3–6 streams (up to 4 cameras + sim render + twin render) at 640x480@30, single
viewer, localhost or 1 GbE LAN.

### 2.1 Bandwidth and CPU arithmetic

- 640x480 JPEG at quality ~80: **25–60 KB/frame** ⇒ **6–15 Mbps per stream** at 30 fps.
  6 streams ⇒ 36–90 Mbps: trivial on loopback, comfortable on 1 GbE.
- `cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])` on a modern desktop CPU:
  ~1–3 ms per 640x480 frame (PyTurboJPEG gets it under 1 ms if it ever matters). 6
  streams × 30 fps × ~2 ms ≈ 0.36 core — negligible. Run encodes in threads
  (`asyncio.to_thread` or the capture thread) so the event loop never blocks; OpenCV
  releases the GIL during encode.

### 2.2 MJPEG over HTTP (`multipart/x-mixed-replace`)

```python
from fastapi.responses import StreamingResponse

async def mjpeg_gen(source):                      # source yields fresh JPEG bytes
    while True:
        jpeg = await source.next_jpeg()           # awaits a *fresh* frame (latest-wins)
        yield (b"--frame\r\n"
               b"Content-Type: image/jpeg\r\n"
               b"Content-Length: " + str(len(jpeg)).encode() + b"\r\n\r\n"
               + jpeg + b"\r\n")

@app.get("/video/{stream_id}.mjpg")
async def video(stream_id: str):
    return StreamingResponse(mjpeg_gen(streams[stream_id]),
                             media_type="multipart/x-mixed-replace; boundary=frame")
```

Client is literally `<img src="/video/cam0.mjpg">` — the browser paints each part as it
arrives, no buffering, no JS.

- **Pros**: simplest possible; viewable in a bare browser tab / VLC (great debug story).
- **Cons**: **one HTTP/1.1 connection per stream**, and Chrome/Firefox cap HTTP/1.1 at
  **6 concurrent connections per origin**. With 6 video streams the pool is saturated and
  REST calls (episode start/stop!) queue behind video. uvicorn is HTTP/1.1-only, so
  HTTP/2 doesn't rescue this. Also: no per-frame metadata (timestamps), no server-side
  awareness of client stalls beyond TCP backpressure.
- Workarounds (serving video from a second port/origin) work but add config friction.

### 2.3 JPEG frames over WebSocket (recommended primary)

Same JPEG bytes, sent as binary WS messages. WS connections are **not** subject to the
6-per-origin HTTP/1.1 pool (browsers allow hundreds), so 6 streams + control + telemetry
coexist happily on one origin. You also get per-frame metadata and clean latest-wins
dropping.

Server pattern — per-client sender task with a **depth-1 latest-frame slot** so a slow
client drops frames instead of accumulating delay:

```python
@app.websocket("/ws/video/{stream_id}")
async def video_ws(ws: WebSocket, stream_id: str):
    await ws.accept()
    sub = streams[stream_id].subscribe()          # asyncio latest-value slot
    try:
        while True:
            jpeg, meta = await sub.next()         # waits for fresh frame; skips missed ones
            await ws.send_bytes(struct.pack("<dI", meta.ts, len(jpeg)) + jpeg)
    except WebSocketDisconnect:
        streams[stream_id].unsubscribe(sub)
```

Client (canvas + `createImageBitmap`, which decodes off the main thread):

```ts
ws.binaryType = "arraybuffer";
ws.onmessage = async (ev) => {
  const dv = new DataView(ev.data);
  const ts = dv.getFloat64(0, true);
  const jpeg = new Blob([new Uint8Array(ev.data, 12)], { type: "image/jpeg" });
  const bmp = await createImageBitmap(jpeg);
  ctx.drawImage(bmp, 0, 0);
  bmp.close();
  updateLatencyBadge(ts);
};
```

(Alternatively skip the binary header and multiplex all streams on one WS with a 1-byte
stream id; per-stream WS is simpler to reason about and reconnect independently.)

### 2.4 WebRTC (aiortc)

aiortc (`pip install aiortc`, BSD-3, ~5.1k stars) implements `RTCPeerConnection`,
`MediaStreamTrack`; you subclass `VideoStreamTrack` and return `av.VideoFrame`s from
`async def recv()`; codecs VP8/H.264 (software encode via PyAV/FFmpeg); signaling via a
single HTTP `POST /offer` exchanging SDP (see `/tmp/aiortc/examples/webcam/webcam.py`,
which also shows `MediaRelay` for multi-viewer fan-out and
`RTCRtpSender.getCapabilities` + `transceiver.setCodecPreferences` for codec forcing).

- **Pros**: 5–10x lower bandwidth (H.264 640x480@30 ≈ 1–2 Mbps), congestion control,
  the right answer for WAN/multi-viewer.
- **Cons**: SDP/ICE signaling machinery, per-track software encode cost, and the
  browser's adaptive **jitter buffer** typically adds 50–200 ms unless tuned
  (`playoutDelayHint`/`jitterBufferTarget = 0` helps but is per-browser). Numerous field
  reports of aiortc pipelines settling at 200–500 ms glass-to-glass without careful
  tuning. All of that machinery buys nothing on loopback/LAN with one viewer.

### 2.5 Latency comparison (engineering estimates, 640x480@30, LAN)

Glass-to-glass = camera exposure/USB (~30–60 ms for a UVC webcam; this dominates and is
identical for all transports) + pipeline latency below:

| Transport | Added pipeline latency | Notes |
|---|---|---|
| MJPEG/HTTP | ~10–40 ms (encode 1–3 ms + TCP <1 ms + decode/paint 5–15 ms + ≤1 frame phase) | No jitter buffer; browser paints on arrival |
| JPEG/WS | same ~10–40 ms | Identical payload path; plus per-frame timestamps for measurement |
| WebRTC (aiortc) | ~60–250 ms (encode 5–15 ms + packetize + jitter buffer 30–200 ms adaptive) | Tunable downward; still the most moving parts |

For this project's requirement ("localhost/LAN, single viewer, 3–5 streams") **WS-JPEG
is simplest and good enough**; keep MJPEG endpoints because they cost ~20 lines and give
a dependency-free debug view. Revisit WebRTC (or WebCodecs + H.264-over-WS) only if
remote/off-LAN operation or bandwidth become real requirements.

---

## 3. Rendering MuJoCo to the browser

### 3.1 Server-side offscreen render → stream as a camera (recommended)

Exact API (from `mujoco/rendering/classic/renderer.py`, MuJoCo 3.12):

```python
import os
os.environ.setdefault("MUJOCO_GL", "egl")          # headless GPU rendering, no X needed
# os.environ["MUJOCO_EGL_DEVICE_ID"] = "1"         # pin to 2nd RTX 4090 if desired
import mujoco

class Renderer:  # signatures, for reference
    def __init__(self, model: mujoco.MjModel, height: int = 240, width: int = 320,
                 max_geom: int = 10000, font_scale=mujoco.mjtFontScale.mjFONTSCALE_150): ...
    def update_scene(self, data: mujoco.MjData,
                     camera: int | str | mujoco.MjvCamera = -1,
                     scene_option: mujoco.MjvOption | None = None): ...
    def render(self, *, out: np.ndarray | None = None) -> np.ndarray: ...  # (H, W, 3) uint8

renderer = mujoco.Renderer(model, height=480, width=640)
renderer.update_scene(data, camera="viewer_cam")
rgb = renderer.render()
jpeg = cv2.imencode(".jpg", cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))[0].tobytes()
```

Gotchas verified in source:

- **Framebuffer size limit**: render size must fit the model's offscreen framebuffer
  (`model.vis.global_.offwidth/offheight`, MJCF defaults 640x480). For larger renders add
  `<visual><global offwidth="1280" offheight="720"/></visual>` to the scene XML, or
  `Renderer.__init__` raises `ValueError`.
- **Thread affinity**: `mujoco.GLContext` "can only be made current on one thread at any
  given time" — create and use each `Renderer` on a single dedicated thread (one render
  thread that owns all renderers and round-robins sim + twin views is the simplest
  design). The EGL display is a lazily-created process-global (`EGL_DISPLAY`), device
  selectable via `MUJOCO_EGL_DEVICE_ID` (integer index; bounds-checked).
- Note in newer MuJoCo, `mujoco.Renderer` is a compat re-export of
  `mujoco.rendering.classic.renderer.Renderer`; a new Filament-based renderer exists but
  classic is the stable path.
- Cost: EGL offscreen 640x480 on an RTX 4090 is far beyond 30 fps; rendering two views at
  20–30 Hz is negligible next to physics.

Because the runtime already owns the sim and the digital twin (`MjModel`/`MjData` live
server-side for collision checking, reset planning, policy inference), a rendered view is
just **another `FrameSource`** feeding the exact same JPEG/WS pipeline as the cameras —
one code path for all live views, and what the operator sees is guaranteed to be the same
state the collision checker used.

### 3.2 MuJoCo WASM in the browser (not recommended here)

Status (from `wasm/README.md` in google-deepmind/mujoco): official bindings now exist —
`npm install @mujoco/mujoco` (ESM, prebuilt WASM, TS declarations; multithreaded variant
`@mujoco/mujoco/mt` needs COOP/COEP headers). They expose `mj_step`, `mj_loadXML`,
`MjModel`/`MjData`/`MjvScene`/`MjvCamera`, named access (`model.geom('name')`), and
`mjv_updateScene`, **but no renderer** — you must map `mjvScene` geoms to three.js
yourself (the community `zalo/mujoco_wasm` demo does exactly this). Explicitly "still a
WIP": manual `.delete()` memory management, experimental Windows support, incomplete
`mjspec` coverage; models load from XML strings via an Emscripten virtual FS (mesh/texture
assets must be staged there).

Why it's wrong for this stack: the browser would be running a *second* physics instance
that immediately diverges from the server-authoritative sim (policy inference, DAgger,
collision checks all happen server-side). Using it render-only would mean streaming full
`qpos` + shipping all meshes to the client + writing a three.js scene builder —
significant work to reproduce what one `mujoco.Renderer` + the existing video path gives
for free. Revisit only if free client-side camera orbiting at zero server cost becomes a
priority; an interactive middle ground is [viser](https://github.com/nerfstudio-project/viser)
(Python → three.js over WS), popular for robot digital-twin views, but it's a separate
server + scene-graph API rather than "the same pixels as the collision checker".

Server-side camera control: expose a small WS/REST verb (`{"t":"set_view", "stream":
"twin", "azimuth":..., "elevation":..., "distance":...}`) mutating the `mjvCamera` used by
`update_scene` — orbiting via drag on the canvas is then easy to wire.

---

## 4. Frontend: React + Vite + TS patterns

React 18 + Vite + TypeScript is a fine default (fast HMR, first-class TS, trivial static
build that FastAPI can serve). No SSR framework needed — this is a local tool.

### 4.1 Keyboard handling for robot teleop

Rules distilled from MDN + game-input practice:

- **Use `event.code`, not `event.key`.** `code` is the *physical* key
  (`"KeyW"`, `"Space"`, `"Tab"`, `"ArrowUp"`), unaffected by layout or Shift — WASD
  keeps its gamepad-cluster meaning on AZERTY (physical ZQSD still emits
  `KeyW/KeyA/KeyS/KeyD`). Use `event.key` only when *displaying* what's printed on the
  operator's keycaps in the hints overlay.
- **Ignore auto-repeat**: `if (e.repeat) return;` — motion derives from held-state, never
  from repeated keydown events.
- **`preventDefault()` aggressively while capturing**: Space scrolls the page, Tab moves
  focus (and it's the switch-arm key), arrows scroll, `/` opens quick-find in Firefox.
  Call `e.preventDefault()` for every bound code while capture is active. Browser-owned
  chords (`Ctrl+W`, `Ctrl+T`, `Cmd+Q`) **cannot** be intercepted — never bind them.
- **Release-all on focus loss**: `window` `blur` and `document` `visibilitychange` must
  clear held state and immediately send an empty `held` message. This plus the server
  watchdog is the belt-and-braces against stuck keys.
- **Explicit capture mode** (the noVNC pattern): a focusable teleop surface
  (`tabIndex={0}`) that the operator clicks to arm, with an unmistakable visual state
  (border/glow + "CAPTURING — click to release" chip). Keys do nothing when a form field
  or the page chrome has focus, so typing an episode label can never jog the robot.

Bespoke hook (this is small enough that a library adds little):

```tsx
const BOUND = new Set(["KeyW","KeyS","KeyA","KeyD","KeyQ","KeyE","KeyI","KeyK","KeyJ","KeyL",
                       "KeyU","KeyO","KeyF","KeyH","Tab","Space",
                       "ArrowLeft","ArrowRight","ArrowUp","ArrowDown"]);

function useKeyCapture(active: boolean, onChange: (held: Set<string>) => void,
                       onAction: (code: string) => void) {
  const held = useRef(new Set<string>());
  useEffect(() => {
    if (!active) return;
    const down = (e: KeyboardEvent) => {
      if (!BOUND.has(e.code)) return;
      e.preventDefault();                       // Tab/Space/arrows especially
      if (e.repeat) return;                     // held-state, not OS key repeat
      if (e.code === "Tab") { onAction("switch_arm"); return; }   // discrete
      held.current.add(e.code); onChange(new Set(held.current));
    };
    const up = (e: KeyboardEvent) => {
      if (!BOUND.has(e.code)) return;
      e.preventDefault();
      held.current.delete(e.code); onChange(new Set(held.current));
    };
    const releaseAll = () => { held.current.clear(); onChange(new Set()); };
    window.addEventListener("keydown", down);
    window.addEventListener("keyup", up);
    window.addEventListener("blur", releaseAll);
    document.addEventListener("visibilitychange",
      () => document.hidden && releaseAll());
    return () => { /* remove all four; releaseAll() on unmount */ };
  }, [active]);
}
```

The component then sends the hybrid protocol of §1.2: `onChange` triggers an immediate
`keys` message, and a `setInterval` (20–50 Hz, running only while `active`) re-sends the
current state as heartbeat. Space (DAgger takeover) is naturally a *held* key in this
model — takeover while held, release on keyup — which matches the requirement.

If a library is preferred, `react-hotkeys-hook` (`useHotkeys(keys, cb, {keydown: true,
keyup: true, preventDefault: true, enableOnFormTags: false}, deps)`, plus
`isHotkeyPressed()` for held-state, scopes via `<HotkeysProvider>`) is maintained and
solid — best for the *discrete* app shortcuts (episode save/discard, page nav), while the
movement cluster stays on the bespoke hook (libraries are keyed on `event.key` by default
and get awkward for layout-independent held-state vectors; it does have a `useKey` option
to flip semantics).

### 4.2 Page/component sketch

- **Landing page**: plain REST forms — `GET /api/profiles`, `GET /api/scenes`,
  `GET /api/cameras` (from `find_cameras()`), `POST /api/session` with
  `{mode, arms:[...], sim_scene, twin_scene, profile}`. Session creation returns the
  stream ids the teleop page will subscribe to.
- **Teleop page**: CSS grid of `<StreamView streamId=... />` canvases (up to 4 cams + sim
  + twin, usually 4 tiles), each with a stale-frame indicator (grey out if no frame for
  >500 ms) and latency badge; `TeleopSurface` (the capture component) wraps the grid;
  `KeymapOverlay` toggled with `?` showing the binding table (W/S/A/D/Q/E translate,
  I/K J/L U/O rotate, F/H gripper, Tab arm, arrows rail, Space DAgger); `CollisionBanner`
  driven by telemetry WS (flash tile borders + names of the offending body pair);
  `EpisodeControls` (start/stop/save/discard → REST; status ← telemetry WS);
  `ArmIndicator` showing active arm + rail position.
- State: one small store (Zustand fits well) holding session, telemetry snapshot,
  connection states; video bytes never touch React state — they go straight
  `WS → createImageBitmap → canvas`.

---

## 5. Camera capture on Linux + abstraction

### 5.1 The abstraction (validated against LeRobot, `src/lerobot/cameras/`)

LeRobot ships exactly the two backends needed and a clean ABC worth copying
(`lerobot/cameras/camera.py`):

```python
class Camera(abc.ABC):
    def __init__(self, config: CameraConfig): ...   # fps, width, height
    @property
    def is_connected(self) -> bool: ...
    @staticmethod
    def find_cameras() -> list[dict]: ...           # enumeration per backend
    def connect(self, warmup: bool = True) -> None: ...
    def read(self) -> np.ndarray: ...               # blocking, next frame
    def async_read(self, timeout_ms: float = 200) -> np.ndarray: ...  # fresh frame, latest-wins
    def read_latest(self, max_age_ms: int = 500) -> np.ndarray: ...   # non-blocking peek, may be stale
    def disconnect(self) -> None: ...
```

Key design points to adopt (all present in LeRobot's implementations):

- **Background capture thread per camera** writing into a lock-protected
  `latest_frame` + `latest_timestamp` slot with a `threading.Event` for freshness. The
  three read flavors map to our consumers: `async_read` for the data-collection loop
  (synchronized to camera fps), `read_latest` for the UI streamer (never block the UI on
  a hung camera; enforce `max_age_ms` and grey the tile), `read` rarely.
- `cv2.setNumThreads(1)` before capture to stop OpenCV spawning thread pools inside the
  loop.
- Config validation on connect: set `CAP_PROP_FOURCC` **first** (`"MJPG"` — most UVC cams
  only reach 30 fps at 640x480+ in MJPG mode, YUYV tops out lower over USB2), then
  `CAP_PROP_FPS`, `CAP_PROP_FRAME_WIDTH/HEIGHT`, and *verify* each `set()` by reading it
  back — V4L2 silently clamps unsupported modes.
- Frames standardized to RGB `np.ndarray (H, W, 3) uint8` at the abstraction boundary
  (OpenCV delivers BGR — convert once, in the capture thread).

### 5.2 OpenCV/V4L2 specifics

- Open by **path**, not index: `cv2.VideoCapture("/dev/video0", cv2.CAP_V4L2)`. Indices
  are unstable across reboots/replug on Linux.
- Enumeration: glob `/dev/video*` and probe with `cv2.VideoCapture` (LeRobot's
  `OpenCVCamera.find_cameras()` does exactly `sorted(Path("/dev").glob("video*"))` then
  reads back default width/height/fps/FOURCC). Caveats: modern kernels expose **two
  nodes per UVC camera** (even = video capture, odd = metadata; the metadata node opens
  but yields no frames — probe with a test `read()` or check
  `v4l2-ctl --list-devices` / sysfs). For **stable identity across reboots**, store
  `/dev/v4l/by-id/usb-...-video-index0` symlinks (or `by-path` for port-based identity)
  in the profile instead of `/dev/videoN`.
- `pyudev` or parsing `v4l2-ctl --list-devices` (package `v4l-utils`) gives
  human-readable names + serials for the landing-page picker.

### 5.3 pyrealsense2 specifics (if RealSense cams are used)

From LeRobot's `camera_realsense.py`:

```python
import pyrealsense2 as rs
ctx = rs.context()
for dev in ctx.query_devices():                      # enumeration
    dev.get_info(rs.camera_info.serial_number)       # stable ID -> store in profile
    dev.get_info(rs.camera_info.name)

pipeline, cfg = rs.pipeline(), rs.config()
rs.config.enable_device(cfg, serial_number)
cfg.enable_stream(rs.stream.color, 640, 480, rs.format.rgb8, 30)
# cfg.enable_stream(rs.stream.depth, 640, 480, rs.format.z16, 30)   # optional
profile = pipeline.start(cfg)
ok, frames = pipeline.try_wait_for_frames(timeout_ms=10000)
color = np.asanyarray(frames.get_color_frame().get_data())          # already RGB8
```

- Identify by **serial number**, never by index/name (names collide with 2+ identical
  cams).
- RealSense color sensors *also* appear as `/dev/video*` UVC nodes — the enumerator must
  de-duplicate (query RealSense serials first, then exclude those USB devices from the
  OpenCV list), and a camera opened via pyrealsense2 will make the V4L2 node "device
  busy" and vice versa.
- LeRobot forces ≥1 s warmup ("RS cameras need a bit of time before the first read") and
  keeps a `device.hardware_reset()` retry path for the common "camera wedged after
  unclean shutdown" failure — worth copying both.
- Depth is available as `rs.stream.z16` if episodes should record it later; the
  abstraction's config should carry an optional `depth: bool` even if v1 ignores it.

Registry pattern: `CameraConfig` tagged-union (`type: "opencv" | "realsense"`, then
`index_or_path` vs `serial_number`), a `make_camera(config) -> Camera` factory, and
`find_all_cameras()` that merges both backends' `find_cameras()` for the landing page.
The sim/twin renderers implement the same *frame-source* protocol (`read_latest()` →
RGB ndarray) so the JPEG/WS streamer is backend-agnostic.

---

## 6. Runtime server architecture

### 6.1 Recommended shape (confirmed sane)

One FastAPI app in apollo-mavis-v2-runtime, one port:

```
/api/...                REST: profiles, scenes, camera enumeration, session lifecycle
                        (POST /api/session, DELETE /api/session), episode start/stop/save,
                        mode switches, reset-plan trigger
/ws/control             control WS (single writer, hybrid key protocol, watchdog)
/ws/telemetry           state broadcast WS (~20-30 Hz, N observers)
/ws/video/{stream_id}   binary JPEG frames (cams + "sim" + "twin" ids)
/video/{stream_id}.mjpg MJPEG debug fallback
/                       SPA static files
```

Serving the SPA:

```python
from fastapi.staticfiles import StaticFiles
app.mount("/", StaticFiles(directory="ui_dist", html=True), name="spa")  # mount LAST
```

Note `StaticFiles(html=True)` serves `index.html` at `/` but 404s deep links like
`/teleop` — either use hash routing in the SPA (fine for a local tool) or add a catch-all
`FileResponse("ui_dist/index.html")` for non-`/api` 404s. In dev, run Vite's dev server
with a proxy instead (`server.proxy = {"/api": ..., "/ws": {target, ws: true},
"/video": ...}`) for HMR.

Process/concurrency layout inside the runtime:

- **Single process, single uvicorn worker** (the FastAPI-docs in-memory
  `ConnectionManager` pattern explicitly only works single-process — which is fine, this
  is a one-operator appliance, and the session state must be singleton anyway).
- Real-time work does **not** live on the event loop: per-camera capture threads
  (§5.1), one MuJoCo render thread owning all `Renderer`s (§3.1 thread affinity), the
  100 Hz+ servo/control loop as its own thread (or `asyncio` task if the xArm SDK calls
  are non-blocking — they aren't; the SDK is sync TCP, so a thread), physics stepping
  for sim mode on its own thread. The asyncio side only shuttles JSON and JPEG bytes.
  Bridge threads → asyncio with `loop.call_soon_threadsafe` / latest-value slots.
- If policy inference or online DAgger training ever stalls the process, split *that*
  into a subprocess (zmq/shared memory) — but keep the web server + control + capture in
  one process to start.

### 6.2 Alternatives considered

- **Separate media server (mediamtx / go2rtc / Janus) + WebRTC**: right call for remote
  operation or many viewers; overkill here (adds a second service, and sim/twin frames
  would need an RTSP/RTP shim).
- **Foxglove / foxglove ws-protocol**: excellent generic robot visualization, but the
  bespoke teleop UX (capture mode, DAgger takeover, episode flow) is the product here;
  Foxglove would be a debug adjunct at best.
- **viser**: attractive for interactive 3D twin view (client-side orbit at no
  bandwidth cost) — reasonable *later addition*, not a replacement for the unified
  stream path.
- **socket.io**: unnecessary — plain WS + the 30-line reconnect wrapper covers the need
  without protocol lock-in on the Python side.
- **gRPC-web / Connect**: heavier tooling for zero benefit at one client on LAN.

---

## 7. Risks / open questions

- **Watchdog semantics need a spec**: exact timeout, decel profile on trip, and the
  "must see empty held-set before resuming" rule should be written into the runtime
  interface (apollo-mavis-v2-core), not left to the web layer.
- **UVC camera latency dominates** (~30–60 ms exposure/USB); if end-to-end teleop feel
  is poor, the fix is camera config (MJPG mode, exposure), not transport.
- **`createImageBitmap` + canvas at 6×30 fps** is normally fine but should be profiled
  once; fallback is decoding in a Worker (`OffscreenCanvas`) — API is Baseline-available
  in Chrome/Firefox.
- MuJoCo classic renderer is being joined by a Filament renderer; pin MuJoCo version and
  the `mujoco.Renderer` import path (`mujoco.rendering.classic.renderer` re-export) in
  the sim repo.
- If two identical non-RealSense USB cams are used, `/dev/v4l/by-id/` may not
  disambiguate (identical serials on cheap cams) — `by-path` (physical port) is the
  fallback; document this in the profile format.
- Browser MJPEG debug endpoints + WS video simultaneously double encode work per stream;
  make the MJPEG generator share the same encoded-JPEG buffer, not re-encode.
- `KeyboardEvent.code` has an MDN "limited availability" flag for some browsers; the
  target here is desktop Chrome/Firefox where it is fully supported — state that
  assumption in the UI README.

## 8. Reference index

- FastAPI WS: https://fastapi.tiangolo.com/advanced/websockets/ (`@app.websocket`,
  `WebSocketDisconnect`, ConnectionManager caveat "single process only")
- uvicorn WS defaults: `uvicorn/config.py` (`ws_per_message_deflate=True` — disable)
- aiortc: https://github.com/aiortc/aiortc — `examples/webcam/webcam.py` (offer/answer
  over HTTP POST, `MediaRelay`, codec forcing)
- MuJoCo Renderer source: `python/mujoco/rendering/classic/renderer.py` (signatures in
  §3.1, offwidth/offheight ValueError); EGL device pinning: `python/mujoco/egl/__init__.py`
  (`MUJOCO_EGL_DEVICE_ID`)
- Official MuJoCo WASM: `wasm/README.md` in google-deepmind/mujoco; npm
  `@mujoco/mujoco` (WIP, no renderer, manual `.delete()`); demo scene-builder:
  https://github.com/zalo/mujoco_wasm (three.js)
- LeRobot camera abstraction: `src/lerobot/cameras/{camera.py, opencv/camera_opencv.py,
  realsense/camera_realsense.py}` (Apache-2.0 — copy patterns freely)
- Keyboard: MDN `KeyboardEvent.code` (physical-key semantics, WASD example,
  keydown/keyup-not-key-repeat guidance); react-hotkeys-hook (`useHotkeys`,
  `isHotkeyPressed`, scopes)
