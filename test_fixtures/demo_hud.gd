extends CanvasLayer

func _on_player_health_changed(new_health: int) -> void:
	print("health: ", new_health)

func _on_player_died() -> void:
	print("game over")
