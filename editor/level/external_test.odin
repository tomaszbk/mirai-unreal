package level

import "core:fmt"
import "core:os"
import "core:testing"
import fixture "project:plugins/unreal/editor/fixture/files"
import unreal "project:plugins/unreal/editor/package"

@(test)
an_external_actor_package_is_named_by_the_hash_of_its_actor_path :: proc(t:^testing.T) {
    // A package that Unreal 5 created for the actor, D/TV/W2Z118IO3S07FEGMDHZK2E.
    digits:=actor_package_digits("/Game/ScifiJungle/Maps/ExampleLevel_Jungle01.ExampleLevel_Jungle01:PersistentLevel.WorldDataLayers")
    testing.expect_value(t,digits,"DTVW2Z118IO3S07FEGMDHZK2E")
    testing.expect(t,external_name_matches("/Game/__ExternalActors__/ScifiJungle/Maps/ExampleLevel_Jungle01/D/TV/W2Z118IO3S07FEGMDHZK2E","/Game/ScifiJungle/Maps/ExampleLevel_Jungle01.ExampleLevel_Jungle01:PersistentLevel.WorldDataLayers"),"the reduced layout, 1/2/22")
    testing.expect(t,external_name_matches("/Game/__ExternalActors__/Map/DT/VW/2Z118IO3S07FEGMDHZK2E","/Game/ScifiJungle/Maps/ExampleLevel_Jungle01.ExampleLevel_Jungle01:PersistentLevel.WorldDataLayers"),"the original layout, 2/2/21")
    testing.expect(t,!external_name_matches("/Game/__ExternalActors__/Map/D/TV/W2Z118IO3S07FEGMDHZK2F","/Game/ScifiJungle/Maps/ExampleLevel_Jungle01.ExampleLevel_Jungle01:PersistentLevel.WorldDataLayers"))
}

@(private="file")
external_actor :: proc(content,relative,actor,label:string) {
    w:=fixture.writer_make({package_name=fmt.tprintf("/Game/__ExternalActors__/Maps/World/%s",relative)})
    map_package:=fixture.import_add(&w,{"/Script/CoreUObject","Package","/Game/Maps/World",0})
    world:=fixture.import_add(&w,{"/Script/Engine","World","Map",map_package})
    level:=fixture.import_add(&w,{"/Script/Engine","Level","PersistentLevel",world})
    props:=fixture.bytes_make()
    fixture.str_property(&props,&w,"ActorLabel",label)
    fixture.none(&props,&w);fixture.put_u32(&props,0)
    fixture.export_add(&w,{class=fixture.engine_class(&w,"Actor"),outer=level,name=actor,data=props.data[:]})
    path:=fmt.tprintf("%s/__ExternalActors__/Maps/World/%s.uasset",content,relative)
    os.make_directory_all(path[:len(path)-len("/xxxxxxxxxxxxxxxxxxxxxx.uasset")])
    _=os.write_entire_file(path,fixture.package_bytes(&w))
}

// Two packages with the actor Sky_0, one named by the hash of its path, and
// two with Ground_0, neither of them: one of each is read, as Unreal loads
// it, and the other is told.
@(test)
of_two_external_packages_with_the_same_actor_one_is_read :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    top:=fmt.tprintf("%s/mirai-unreal-external-%d",directory,os.get_pid())
    os.remove_all(top)
    defer os.remove_all(top)
    content:=fmt.tprintf("%s/Content",top)
    os.make_directory_all(fmt.tprintf("%s/Maps",content))
    l:=fixture.level_begin("/Game/Maps/World")
    l.properties=fixture.bytes_make()
    fixture.bool_property(&l.properties,&l.w,"bUseExternalActors",true)
    _=os.write_entire_file(fmt.tprintf("%s/Maps/World.umap",content),fixture.level_bytes(&l))

    sky:=actor_package_digits("/Game/Maps/World.Map:PersistentLevel.Sky_0")
    external_actor(content,"0/00/0000000000000000000000","Sky_0","Sky left behind")
    external_actor(content,fmt.tprintf("%s/%s/%s",sky[:1],sky[1:3],sky[3:]),"Sky_0","Sky")
    external_actor(content,"1/AA/AAAAAAAAAAAAAAAAAAAAAA","Ground_0","Ground")
    external_actor(content,"2/BB/BBBBBBBBBBBBBBBBBBBBBB","Ground_0","Ground left behind")
    external_actor(content,"3/CC/CCCCCCCCCCCCCCCCCCCCCC","Rock_0","Rock")

    lib:Library
    library_init(&lib,[]unreal.Source_Mount{{"/Game",content}})
    defer library_destroy(&lib)
    map_index,find_error:=library_find(&lib,"/Game/Maps/World")
    if !testing.expect_value(t,find_error.code,unreal.Error_Code.None) {return}
    d:Document
    if !testing.expect_value(t,document_open(&d,&lib,map_index).code,unreal.Error_Code.None) {return}
    defer document_destroy(&d)
    labels:[dynamic]string
    labels.allocator=context.temp_allocator
    for actor in d.actors {append(&labels,actor.label)}
    testing.expect_value(t,len(labels),3)
    for label in labels {testing.expectf(t,label=="Sky" || label=="Ground" || label=="Rock","%s is read",label)}
    if !testing.expect_value(t,len(d.superseded),2) {return}
    for item in d.superseded {
        switch item.actor {
        case "/Game/Maps/World.Map:PersistentLevel.Sky_0":
            testing.expect_value(t,item.left,"/Game/__ExternalActors__/Maps/World/0/00/0000000000000000000000")
        case "/Game/Maps/World.Map:PersistentLevel.Ground_0":
            testing.expect_value(t,item.left,"/Game/__ExternalActors__/Maps/World/2/BB/BBBBBBBBBBBBBBBBBBBBBB")
        case:
            testing.expectf(t,false,"%s was not left",item.actor)
        }
    }
}
