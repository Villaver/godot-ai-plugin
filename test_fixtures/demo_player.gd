extends CharacterBody2D

signal health_changed(new_health: int)
signal died

@export var max_health: int = 100
var health: int = 100

func take_damage(amount: int) -> void:
	health = maxi(0, health - amount)
	health_changed.emit(health)
	if health <= 0:
		died.emit()
