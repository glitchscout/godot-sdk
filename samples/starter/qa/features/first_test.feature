Feature: The vault

  Scenario: The bot finds the key and opens the vault
    Given the player is in scene "res://vault.tscn"
    When the player collects "vault_key"
    And the player uses "vault_door"
    Then the event "door_opened" should occur
    And "vault_door" should be "open"
    And no script errors should be logged

  Scenario: The key opens the door
    Given the player is in scene "res://vault.tscn"
    And the player has "vault_key"
    And the player is at 0, 1, -2
    When the player presses "interact"
    Then "vault_door" should be "open" within 2 seconds
