package unreal

import "core:testing"

@(test)
asset_names_go_without_the_prefix_of_their_type :: proc(t:^testing.T) {
    testing.expect_value(t,asset_name("SM_APV2_Rock1"),"APV2_Rock1")
    testing.expect_value(t,asset_name("MI_APV2_Grass"),"APV2_Grass")
    testing.expect_value(t,asset_name("T_APV2_Landscape_Dirt_Dif"),"APV2_Landscape_Dirt_Dif")
    testing.expect_value(t,asset_name("SKM_Manny"),"Manny")
    testing.expect_value(t,asset_name("BP_APV2_GlowingSphere"),"APV2_GlowingSphere")
    testing.expect_value(t,asset_name("Sphere"),"Sphere")
    testing.expect_value(t,asset_name("Rock_SM"),"Rock_SM")
    testing.expect_value(t,asset_name("SM_"),"SM_")
    testing.expect_value(t,asset_name("sm_rock"),"sm_rock")
}
