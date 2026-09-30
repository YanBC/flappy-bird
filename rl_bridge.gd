extends Node
## TCP bridge that lets an external process (e.g. a Python RL trainer) drive the
## game. Listens on 127.0.0.1 and speaks newline-delimited JSON, one response
## per request:
##
##   {"cmd": "reset", "seed": 123}
##       -> {"obs": [6 floats], "score": 0}
##   {"cmd": "step", "action": 0 | 1, "repeat": 2}
##       -> {"obs": [...], "reward": 0.1, "terminated": false, "score": 3}
##   {"cmd": "close"}
##       -> quits Godot
##
## "action" 1 flaps on the first of the "repeat" ticks. Reward per step:
## +0.1 for surviving, +1 per pipe passed, -1 on crashing.

const REWARD_ALIVE := 0.1
const REWARD_PIPE := 1.0
const REWARD_CRASH := -1.0
## Headless: how long one frame may spend serving requests before yielding.
const FRAME_BUDGET_USEC := 50_000

var game: Node
var port := 11008
## One step per rendered frame (paced to real time) so a human can watch.
var watch := false

var _server := TCPServer.new()
var _peer: StreamPeerTCP
var _buffer := PackedByteArray()


func _ready() -> void:
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("RL bridge: cannot listen on port %d (error %d)" % [port, err])
		get_tree().quit(1)
		return
	print("RL bridge listening on 127.0.0.1:%d" % port)


func _process(_delta: float) -> void:
	if _peer == null:
		if not _server.is_connection_available():
			return
		_peer = _server.take_connection()
		_peer.set_no_delay(true)  # tiny request/response messages; Nagle would add latency
		_buffer.clear()

	var deadline := Time.get_ticks_usec() + FRAME_BUDGET_USEC
	while true:
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_peer = null
			return
		var available := _peer.get_available_bytes()
		if available > 0:
			_buffer.append_array(_peer.get_partial_data(available)[1])

		var newline := _buffer.find(10)
		if newline >= 0:
			var line := _buffer.slice(0, newline).get_string_from_utf8()
			_buffer = _buffer.slice(newline + 1)
			_handle(line)
			if watch:
				return
		elif watch or Time.get_ticks_usec() >= deadline:
			return
		else:
			OS.delay_usec(20)


func _handle(line: String) -> void:
	var msg = JSON.parse_string(line)
	if typeof(msg) != TYPE_DICTIONARY:
		_send({"error": "invalid JSON request"})
		return

	match msg.get("cmd"):
		"reset":
			game.agent_reset(int(msg.get("seed", randi())))
			_send({"obs": game.agent_observation(), "score": 0})
		"step":
			var repeat := maxi(1, int(msg.get("repeat", 1)))
			var flap := int(msg.get("action", 0)) == 1
			var score_before: int = game.score
			var crashed := false
			for i in repeat:
				crashed = game.agent_step(flap and i == 0)
				if crashed:
					break
			if watch:
				Engine.max_fps = maxi(1, roundi(60.0 / repeat))
			var reward := REWARD_CRASH if crashed else REWARD_ALIVE
			reward += (game.score - score_before) * REWARD_PIPE
			_send({
				"obs": game.agent_observation(),
				"reward": reward,
				"terminated": crashed,
				"score": game.score,
			})
		"close":
			get_tree().quit()
		var other:
			_send({"error": "unknown cmd: %s" % other})


func _send(data: Dictionary) -> void:
	_peer.put_data((JSON.stringify(data) + "\n").to_utf8_buffer())
