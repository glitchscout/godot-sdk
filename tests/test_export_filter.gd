extends GdUnitTestSuite
## The shipping-exclusion rules the addon's export plugin applies (the plugin itself only loads in the editor).

const ExportFilter := preload("res://addons/glitchscout/export_filter.gd")


func test_a_preset_excludes_the_sdk_only_when_its_filter_covers_the_addon() -> void:
	assert_bool(ExportFilter.excludes_sdk("addons/glitchscout/*, tests/*")).is_true()
	assert_bool(ExportFilter.excludes_sdk("res://addons/glitchscout/*")).is_true()
	assert_bool(ExportFilter.excludes_sdk("tests/*,addons/*")).is_true()
	assert_bool(ExportFilter.excludes_sdk("addons/gdUnit4/*, tests/*")).is_false()
	assert_bool(ExportFilter.excludes_sdk("")).is_false()
	assert_bool(ExportFilter.excludes_sdk("*.gd")).is_true() # Godot also matches globs against the file name
	assert_bool(ExportFilter.excludes_sdk("*.png")).is_false()


func test_shipping_settings_drop_the_autoload_and_only_the_sdks_plugin_entry() -> void:
	assert_that(ExportFilter.without_sdk("autoload/Glitchscout", "*res://addons/glitchscout/glitchscout.gd")).is_null()
	var both := PackedStringArray(["res://addons/glitchscout/plugin.cfg", "res://addons/other/plugin.cfg"])
	assert_array(Array(ExportFilter.without_sdk("editor_plugins/enabled", both))).contains_exactly(["res://addons/other/plugin.cfg"])
	assert_that(ExportFilter.without_sdk("editor_plugins/enabled", PackedStringArray(["res://addons/glitchscout/plugin.cfg"]))).is_null()


func test_a_shipping_export_is_a_release_export_without_the_qa_tag() -> void:
	assert_bool(ExportFilter.is_shipping(PackedStringArray(["release"]), false)).is_true()
	assert_bool(ExportFilter.is_shipping(PackedStringArray(["release", "qa"]), false)).is_false()
	assert_bool(ExportFilter.is_shipping(PackedStringArray(["debug"]), true)).is_false()
