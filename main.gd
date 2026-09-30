extends Node2D
## Flappy Bird — everything (physics, pipes, visuals, UI, sound) lives in this
## one script; graphics are drawn and sounds synthesized procedurally, so the
## project needs no asset files.
##
## Run with `-- --rl --port=N` to hand control to an external agent over TCP
## (see rl_bridge.gd and python/).

const W := 432.0
const H := 768.0
const GROUND_H := 96.0
const PLAY_H := H - GROUND_H

const GRAVITY := 1500.0
const FLAP_VELOCITY := -460.0
const MAX_FALL_SPEED := 900.0

const PIPE_SPEED := 160.0
const PIPE_WIDTH := 72.0
const PIPE_GAP := 170.0
const PIPE_SPACING := 230.0
const PIPE_MARGIN := 90.0
const CAP_H := 28.0
const CAP_OVERHANG := 6.0

const BIRD_X := 120.0
const BIRD_R := 16.0

const RESTART_DELAY := 0.6
const SAVE_PATH := "user://highscore.save"
const SAMPLE_RATE := 22050
const TICK := 1.0 / 60.0

const SKY := Color("4ec0ca")
const CLOUD := Color("e9fcd9")
const PIPE := Color("73bf2e")
const PIPE_DARK := Color("558022")
const PIPE_LIGHT := Color("9ce659")
const GROUND := Color("ded895")
const GRASS := Color("73bf2e")
const GRASS_DARK := Color("5a9c22")
const BIRD_BODY := Color("f8d030")
const BIRD_BELLY := Color("fbeaa0")
const BIRD_WING := Color("f0a818")
const BEAK := Color("f06020")
const OUTLINE := Color("543847")

enum State { READY, PLAYING, DEAD }

var state := State.READY
var bird_y := 0.0
var bird_vy := 0.0
var bird_rot := 0.0
var pipes: Array[Dictionary] = []  # {x: float, gap_y: float, scored: bool}
var clouds: Array[Vector3] = []    # x, y, radius
var score := 0
var best := 0
var time := 0.0
var ground_offset := 0.0
var dead_timer := 0.0
var flash := 0.0
var font: Font
var sfx_flap: AudioStreamPlayer
var sfx_score: AudioStreamPlayer
var sfx_crash: AudioStreamPlayer
var rng := RandomNumberGenerator.new()  # pipe layout only, so agents can seed it
var agent_mode := false
var headless := DisplayServer.get_name() == "headless"


func _ready() -> void:
	font = ThemeDB.fallback_font
	best = _load_best()
	rng.randomize()
	_setup_sounds()
	for i in 7:
		clouds.append(Vector3(i * 75.0, PLAY_H - randf_range(20, 70), randf_range(30, 50)))
	_reset()
	_setup_agent_bridge()


func _setup_agent_bridge() -> void:
	var args := OS.get_cmdline_user_args()
	if "--rl" not in args:
		return
	agent_mode = true
	var bridge: Node = preload("res://rl_bridge.gd").new()
	bridge.game = self
	for arg in args:
		if arg.begins_with("--port="):
			bridge.port = int(arg.trim_prefix("--port="))
		elif arg == "--watch":
			bridge.watch = true
	add_child(bridge)


func _reset() -> void:
	state = State.READY
	bird_y = H * 0.42
	bird_vy = 0.0
	bird_rot = 0.0
	pipes.clear()
	score = 0


func _unhandled_input(event: InputEvent) -> void:
	var pressed := false
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_SPACE, KEY_UP, KEY_W, KEY_ENTER]:
			pressed = true
		elif event.keycode == KEY_M:
			AudioServer.set_bus_mute(0, not AudioServer.is_bus_mute(0))
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Touch input on mobile is emulated as mouse clicks by default.
		pressed = true
	if pressed:
		_on_tap()


func _on_tap() -> void:
	if agent_mode:
		return
	match state:
		State.READY:
			state = State.PLAYING
			_flap()
		State.PLAYING:
			_flap()
		State.DEAD:
			if dead_timer >= RESTART_DELAY:
				_reset()


func _flap() -> void:
	bird_vy = FLAP_VELOCITY
	sfx_flap.pitch_scale = randf_range(0.95, 1.05)
	sfx_flap.play()


func _process(_delta: float) -> void:
	if not headless:
		queue_redraw()


func _physics_process(delta: float) -> void:
	# In agent mode the bridge advances the game explicitly via agent_step().
	if not agent_mode:
		_tick(delta)


## Advances the whole simulation by one fixed step.
func _tick(delta: float) -> void:
	time += delta
	flash = maxf(flash - delta * 3.0, 0.0)

	if state != State.DEAD:
		ground_offset = fmod(ground_offset + PIPE_SPEED * delta, 24.0)
		for i in clouds.size():
			var c := clouds[i]
			c.x -= PIPE_SPEED * 0.15 * delta
			if c.x < -c.z:
				c.x += clouds.size() * 75.0
			clouds[i] = c

	match state:
		State.READY:
			bird_y = H * 0.42 + sin(time * 6.0) * 8.0
		State.PLAYING:
			_update_bird(delta)
			_update_pipes(delta)
			if _check_collision():
				_die()
		State.DEAD:
			dead_timer += delta
			if bird_y < PLAY_H - BIRD_R:
				_update_bird(delta)
			bird_y = minf(bird_y, PLAY_H - BIRD_R)


func _update_bird(delta: float) -> void:
	bird_vy = minf(bird_vy + GRAVITY * delta, MAX_FALL_SPEED)
	bird_y += bird_vy * delta
	if bird_y < BIRD_R:
		bird_y = BIRD_R
		bird_vy = 0.0
	# Nose up while rising, dive while falling fast.
	var target_rot := clampf(bird_vy / 600.0, -0.45, 1.5)
	bird_rot = lerpf(bird_rot, target_rot, minf(delta * 10.0, 1.0))


func _update_pipes(delta: float) -> void:
	if pipes.is_empty() or pipes.back()["x"] < W - PIPE_SPACING:
		var half_gap := PIPE_GAP / 2.0
		var gap_y := rng.randf_range(PIPE_MARGIN + half_gap, PLAY_H - PIPE_MARGIN - half_gap)
		pipes.append({"x": W + 20.0, "gap_y": gap_y, "scored": false})

	for p in pipes:
		p["x"] -= PIPE_SPEED * delta
		if not p["scored"] and p["x"] + PIPE_WIDTH < BIRD_X:
			p["scored"] = true
			score += 1
			sfx_score.play()

	while not pipes.is_empty() and pipes.front()["x"] < -PIPE_WIDTH - CAP_OVERHANG:
		pipes.pop_front()


func _check_collision() -> bool:
	if bird_y + BIRD_R >= PLAY_H:
		bird_y = PLAY_H - BIRD_R
		return true
	var center := Vector2(BIRD_X, bird_y)
	# Slightly smaller hitbox than the drawn bird feels fairer.
	var r := BIRD_R - 2.0
	for p in pipes:
		for rect in _pipe_rects(p):
			var closest := center.clamp(rect.position, rect.end)
			if center.distance_squared_to(closest) < r * r:
				return true
	return false


func _pipe_rects(p: Dictionary) -> Array[Rect2]:
	var top_end: float = p["gap_y"] - PIPE_GAP / 2.0
	var bottom_start: float = p["gap_y"] + PIPE_GAP / 2.0
	return [
		Rect2(p["x"], -1000.0, PIPE_WIDTH, top_end + 1000.0),
		Rect2(p["x"], bottom_start, PIPE_WIDTH, PLAY_H - bottom_start),
	]


func _die() -> void:
	state = State.DEAD
	dead_timer = 0.0
	flash = 1.0
	sfx_crash.play()
	if score > best and not agent_mode:
		best = score
		_save_best()


# --- Agent API (driven by rl_bridge.gd) --------------------------------------

## Starts a new episode straight in the PLAYING state with a seeded pipe layout.
func agent_reset(seed_value: int) -> void:
	_reset()
	rng.seed = seed_value
	state = State.PLAYING


## Advances one tick, flapping first if asked. Returns true once the bird has crashed.
func agent_step(flap: bool) -> bool:
	if state == State.PLAYING:
		if flap:
			_flap()
		_tick(TICK)
	return state == State.DEAD


## Normalized features: bird height and velocity, then for the next two pipes
## the horizontal distance to the pipe's far edge and the gap center's offset
## from the bird. Missing pipes read as far away and level with the bird.
func agent_observation() -> Array[float]:
	var obs: Array[float] = [bird_y / PLAY_H, bird_vy / MAX_FALL_SPEED]
	var ahead := pipes.filter(func(p: Dictionary) -> bool:
		return p["x"] + PIPE_WIDTH >= BIRD_X - BIRD_R)
	for i in 2:
		if i < ahead.size():
			obs.append((ahead[i]["x"] + PIPE_WIDTH - BIRD_X) / W)
			obs.append((ahead[i]["gap_y"] - bird_y) / PLAY_H)
		else:
			obs.append(1.0)
			obs.append(0.0)
	return obs


# --- Sound -------------------------------------------------------------------

func _setup_sounds() -> void:
	# Flap: quick rising "whoop".
	sfx_flap = _make_sound(0.1, -8.0, func(t: float) -> float:
		var d := 0.1
		var phase := TAU * (380.0 * t + (900.0 - 380.0) * t * t / (2.0 * d))
		return sin(phase) * pow(1.0 - t / d, 2.0))

	# Score: two-note coin chime (B5 -> E6).
	sfx_score = _make_sound(0.3, -10.0, func(t: float) -> float:
		var split := 0.07
		var f := 988.0 if t < split else 1319.0
		var env := 1.0 if t < split else exp(-(t - split) * 12.0)
		var x := TAU * f * t
		return (sin(x) + 0.3 * sin(2.0 * x)) * 0.7 * env)

	# Crash: filtered noise burst over a falling low thump.
	var lp := [0.0]  # one-pole low-pass state, in an array so the lambda can mutate it
	sfx_crash = _make_sound(0.4, -4.0, func(t: float) -> float:
		lp[0] = lerpf(lp[0], randf_range(-1.0, 1.0), 0.35)
		var noise: float = lp[0] * exp(-t * 12.0)
		var thump := sin(TAU * (160.0 * t - 120.0 * t * t)) * exp(-t * 7.0)
		return noise * 0.6 + thump * 0.55)


func _make_sound(duration: float, volume_db: float, sample: Callable) -> AudioStreamPlayer:
	var n := int(duration * SAMPLE_RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var fade_len := int(0.01 * SAMPLE_RATE)  # short fade-out avoids a click at the end
	for i in n:
		var v := clampf(sample.call(float(i) / SAMPLE_RATE), -1.0, 1.0)
		v *= minf(float(n - 1 - i) / fade_len, 1.0)
		data.encode_s16(i * 2, int(v * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = data

	var player := AudioStreamPlayer.new()
	player.stream = wav
	player.volume_db = volume_db
	add_child(player)
	return player


# --- Persistence -------------------------------------------------------------

func _load_best() -> int:
	if not FileAccess.file_exists(SAVE_PATH):
		return 0
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	return f.get_32() if f else 0


func _save_best() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_32(best)


# --- Drawing -----------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(0, 0, W, H), SKY)
	for c in clouds:
		draw_circle(Vector2(c.x, c.y), c.z, CLOUD)
	draw_rect(Rect2(0, PLAY_H - 40, W, 40), CLOUD)

	for p in pipes:
		_draw_pipe(p)
	_draw_ground()
	_draw_bird()
	_draw_ui()

	if flash > 0.0:
		draw_rect(Rect2(0, 0, W, H), Color(1, 1, 1, flash * 0.8))


func _draw_pipe(p: Dictionary) -> void:
	var x: float = p["x"]
	var top_end: float = p["gap_y"] - PIPE_GAP / 2.0
	var bottom_start: float = p["gap_y"] + PIPE_GAP / 2.0
	# Top pipe: body hangs down from the sky, cap at its lower end.
	_draw_pipe_segment(Rect2(x, 0, PIPE_WIDTH, top_end - CAP_H))
	_draw_pipe_segment(Rect2(x - CAP_OVERHANG, top_end - CAP_H, PIPE_WIDTH + CAP_OVERHANG * 2, CAP_H))
	# Bottom pipe: cap at its upper end, body down to the ground.
	_draw_pipe_segment(Rect2(x - CAP_OVERHANG, bottom_start, PIPE_WIDTH + CAP_OVERHANG * 2, CAP_H))
	_draw_pipe_segment(Rect2(x, bottom_start + CAP_H, PIPE_WIDTH, PLAY_H - bottom_start - CAP_H))


func _draw_pipe_segment(r: Rect2) -> void:
	if r.size.y <= 0.0:
		return
	draw_rect(r, PIPE)
	draw_rect(Rect2(r.position.x + 6, r.position.y, 8, r.size.y), PIPE_LIGHT)
	draw_rect(Rect2(r.end.x - 14, r.position.y, 10, r.size.y), PIPE_DARK)
	draw_rect(r, OUTLINE, false, 3.0)


func _draw_ground() -> void:
	draw_rect(Rect2(0, PLAY_H, W, GROUND_H), GROUND)
	draw_rect(Rect2(0, PLAY_H, W, 18), GRASS)
	# Scrolling diagonal stripes on the grass strip.
	var x := -ground_offset - 24.0
	while x < W + 24.0:
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, PLAY_H + 18), Vector2(x + 12, PLAY_H + 18),
			Vector2(x + 24, PLAY_H), Vector2(x + 12, PLAY_H),
		]), GRASS_DARK)
		x += 24.0
	draw_line(Vector2(0, PLAY_H), Vector2(W, PLAY_H), OUTLINE, 3.0)
	draw_line(Vector2(0, PLAY_H + 18), Vector2(W, PLAY_H + 18), Color(OUTLINE, 0.4), 2.0)


func _draw_bird() -> void:
	draw_set_transform(Vector2(BIRD_X, bird_y), bird_rot)

	var flapping := state != State.DEAD
	var wing_y := sin(time * 22.0) * 5.0 if flapping else 0.0

	_draw_ellipse(Vector2.ZERO, Vector2(BIRD_R + 3, BIRD_R), OUTLINE)
	_draw_ellipse(Vector2.ZERO, Vector2(BIRD_R, BIRD_R - 3), BIRD_BODY)
	_draw_ellipse(Vector2(2, 6), Vector2(BIRD_R - 5, 6), BIRD_BELLY)
	# Wing
	_draw_ellipse(Vector2(-8, 2 + wing_y), Vector2(10, 7), OUTLINE)
	_draw_ellipse(Vector2(-8, 2 + wing_y), Vector2(8, 5), BIRD_WING)
	# Eye
	draw_circle(Vector2(8, -6), 7, OUTLINE)
	draw_circle(Vector2(8, -6), 5.5, Color.WHITE)
	if state == State.DEAD:
		draw_line(Vector2(6, -8), Vector2(12, -2), OUTLINE, 2.0)
		draw_line(Vector2(12, -8), Vector2(6, -2), OUTLINE, 2.0)
	else:
		draw_circle(Vector2(10, -6), 2.5, OUTLINE)
	# Beak
	draw_colored_polygon(PackedVector2Array([
		Vector2(13, -1), Vector2(26, 3), Vector2(13, 8),
	]), BEAK)
	draw_polyline(PackedVector2Array([
		Vector2(13, -1), Vector2(26, 3), Vector2(13, 8),
	]), OUTLINE, 2.0)

	draw_set_transform(Vector2.ZERO)


func _draw_ellipse(center: Vector2, radii: Vector2, color: Color, segments := 24) -> void:
	var pts := PackedVector2Array()
	for i in segments:
		var a := TAU * i / segments
		pts.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	draw_colored_polygon(pts, color)


func _draw_ui() -> void:
	match state:
		State.READY:
			_text("Flappy Bird", 200, 52)
			_text("Tap / Space to flap", 470, 26)
			_text("M to mute", 545, 18)
			if best > 0:
				_text("Best: %d" % best, 505, 22)
		State.PLAYING:
			_text(str(score), 110, 64)
		State.DEAD:
			_text("Game Over", 210, 52)
			var panel := Rect2(W / 2 - 120, 250, 240, 130)
			draw_rect(panel, Color("ded895"))
			draw_rect(panel, OUTLINE, false, 4.0)
			_text("Score: %d" % score, 305, 30)
			_text("Best: %d" % best, 355, 30)
			if dead_timer >= RESTART_DELAY:
				_text("Tap to restart", 450, 26)


func _text(s: String, y: float, size: int) -> void:
	var outline := maxi(int(size * 0.2), 4)
	draw_string_outline(font, Vector2(0, y), s, HORIZONTAL_ALIGNMENT_CENTER, W, size, outline, OUTLINE)
	draw_string(font, Vector2(0, y), s, HORIZONTAL_ALIGNMENT_CENTER, W, size, Color.WHITE)
