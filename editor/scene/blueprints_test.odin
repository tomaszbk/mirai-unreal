package unreal_scene

import "core:testing"
import "mirai:asset"
import "mirai:std/base"

// Siblings that share a name, as the components a Blueprint adds in its
// construction script, get places of their own, and a leaf has no children.
@(test)
subtree_places_tell_apart_siblings_that_share_a_name :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_init(&scene,&types,asset.KIND_SCENE,{},context.temp_allocator),asset.Error.None) {return}
    defer asset.scene_destroy(&scene)
    room,first,second,bulb:=base.Entity_Id(1),base.Entity_Id(2),base.Entity_Id(3),base.Entity_Id(4)
    asset.scene_entity_add(&scene,room,0,"Room")
    asset.scene_entity_add(&scene,first,room,"Light")
    asset.scene_entity_add(&scene,second,room,"Light")
    asset.scene_entity_add(&scene,bulb,second,"Bulb")
    children:=children_of(&scene)
    places:=subtree_places(&scene,&children,room)
    testing.expect_value(t,len(places),4)
    testing.expect_value(t,places[room],"")
    testing.expect_value(t,places[first],"Light")
    testing.expect_value(t,places[second],"Light#1")
    testing.expect_value(t,places[bulb],"Light#1/Bulb")
}
