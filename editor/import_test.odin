package unreal_editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import "mirai:project"
import fixture "project:plugins/unreal/editor/fixture/files"
import fx "project:plugins/unreal/editor/material/fixture"
import uasset "project:plugins/unreal/editor/model"
import unreal_scene "project:plugins/unreal/editor/scene"

@(private="file")
temp_folder :: proc(name:string) -> string {
    directory,_:=os.temp_directory(context.temp_allocator)
    path,_:=strings.replace_all(fmt.tprintf("%s/mirai-unreal-%d-%s",directory,os.get_pid(),name),"\\","/",context.temp_allocator)
    os.remove_all(path)
    os.make_directory_all(path)
    return path
}

// A quad of a StaticMesh saved by UE4 as FRawMesh, in two slots.
@(private="file")
unreal_quad :: proc() -> []u8 {
    up:=[3]f32{0,0,1}
    f:fixture.Mesh_Fixture
    f.layout=.Raw_Mesh
    f.positions=slice.clone([][3]f32{{0,0,0},{100,0,0},{100,100,0},{0,100,0}},context.temp_allocator)
    f.corners=slice.clone([]u32{0,2,1, 0,3,2},context.temp_allocator)
    f.normals=slice.clone([][3]f32{up,up,up,up,up,up},context.temp_allocator)
    f.uvs=slice.clone([][2]f32{{0,1},{1,0},{1,1},{0,1},{0,0},{1,0}},context.temp_allocator)
    f.groups=slice.clone([]u32{0,1},context.temp_allocator)
    f.smoothing=slice.clone([]u32{1,1},context.temp_allocator)
    f.slots=slice.clone([]fixture.Mesh_Slot{{name="Wood",imported_name="Wood",material="/Game/Materials/M_Wood"},{name="Metal",imported_name="Metal",material="/Game/Materials/M_Metal"}},context.temp_allocator)
    return fixture.static_mesh_package(f)
}

// The formats the editor imports with this plugin: those of the engine and the one it gives.
@(private="file")
formats_with_unreal :: proc() -> []importer.Format {
    out:=make([dynamic]importer.Format,context.temp_allocator)
    append(&out,..sources.FORMATS[:])
    append(&out,unreal_format_default().provider.format)
    return out[:]
}

@(test)
an_unreal_static_mesh_imports_as_its_mesh_materials_and_prefab :: proc(t:^testing.T) {
    folder:=temp_folder("static")
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/SM_Fixture.uasset",folder)
    _=os.write_entire_file(path,unreal_quad())
    formats:=formats_with_unreal()
    testing.expect_value(t,sources.source_kind(path,formats),sources.Source_Kind.Model)
    testing.expect_value(t,sources.source_kind(path,sources.FORMATS[:]),sources.Source_Kind.None)
    testing.expect_value(t,sources.model_folder(path,formats),"Fixture")
    report,error:=sources.import_source(path,fmt.tprintf("%s/out",folder),{no_save=true},formats)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.report_destroy(&report)
    kinds:map[asset.Fourcc]int
    kinds.allocator=context.temp_allocator
    for written in report.assets {kinds[written.kind]+=1}
    testing.expect_value(t,kinds[asset.KIND_MESH],1)
    testing.expect_value(t,kinds[asset.KIND_MATERIAL],2)
    testing.expect_value(t,kinds[asset.KIND_PREFAB],1)
}

@(test)
an_unreal_skeletal_mesh_imports_as_its_skinned_mesh_skeleton_materials_and_prefab :: proc(t:^testing.T) {
    folder:=temp_folder("skeletal")
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/SK_Fixture.uasset",folder)
    _=os.write_entire_file(path,fixture.skeletal_mesh_package(fixture.skeletal_figure(.UE5)))
    report,error:=sources.import_source(path,fmt.tprintf("%s/out",folder),{no_save=true},formats_with_unreal())
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer importer.report_destroy(&report)
    kinds:map[asset.Fourcc]int
    kinds.allocator=context.temp_allocator
    for written in report.assets {
        kinds[written.kind]+=1
        if written.kind==asset.KIND_MESH || written.kind==asset.KIND_SKELETON || written.kind==asset.KIND_PREFAB {
            a:asset.Asset
            testing.expectf(t,asset.asset_load(&a,written.path,context.temp_allocator)==.None,"%s reads back",written.path)
            asset.asset_close(&a)
        }
    }
    testing.expect_value(t,kinds[asset.KIND_MESH],1)
    testing.expect_value(t,kinds[asset.KIND_SKELETON],1)
    testing.expect_value(t,kinds[asset.KIND_MATERIAL],2)
    testing.expect_value(t,kinds[asset.KIND_PREFAB],1)
    testing.expect_value(t,len(report.skeleton_ids),1)
}

// A package cut at any length, or with any byte changed, is either imported
// or refused: never a crash and never a leak (the runner checks the memory).
@(test)
damaged_unreal_packages_are_imported_or_refused :: proc(t:^testing.T) {
    folder:=temp_folder("fuzz")
    defer os.remove_all(folder)
    // An empty /Engine of its own: the same attempts with or without Unreal installed.
    options:=uasset.Options{engine_content=fmt.tprintf("%s/Engine",folder)}
    _=os.make_directory(options.engine_content)
    formats:=[1]importer.Format{uasset.format(&options)}
    path:=fmt.tprintf("%s/subject.uasset",folder)
    attempt :: proc(path:string,data:[]u8,formats:[]importer.Format,imported,refused:^int) {
        if os.write_entire_file(path,data)!=nil {return}
        model,error:=importer.import_model(path,formats,{ignore_stored=true})
        if error.code==.None {
            importer.model_destroy(&model)
            imported^+=1
        } else {refused^+=1}
    }
    for bytes in ([?][]u8{unreal_quad(),fixture.skeletal_mesh_package(fixture.skeletal_figure(.UE5))}) {
        imported,refused:=0,0
        for length in 0..<len(bytes) {attempt(path,bytes[:length],formats[:],&imported,&refused)}
        mutated:=make([]u8,len(bytes),context.temp_allocator)
        for position:=0;position<len(bytes);position+=1+len(bytes)/1000 {
            copy(mutated,bytes)
            mutated[position]~=0xff
            attempt(path,mutated,formats[:],&imported,&refused)
            copy(mutated,bytes)
            mutated[position]=0
            attempt(path,mutated,formats[:],&imported,&refused)
        }
        testing.expectf(t,refused>0,"some of the %d damaged packages are refused",imported+refused)
    }
}

// A map with one StaticMeshActor showing the quad, and the Unreal project
// that holds both, next to a project of Mirai.
@(private="file")
unreal_level_folders :: proc(name:string) -> (top,mirai,level:string) {
    top=temp_folder(name)
    mirai=fmt.tprintf("%s/project",top)
    os.make_directory_all(mirai)
    m:=project.manifest_default("Levels")
    project.manifest_write(project.path(mirai,project.PROJECT_FILE,allocator=context.temp_allocator),&m)
    unreal:=fmt.tprintf("%s/Unreal",top)
    os.make_directory_all(fmt.tprintf("%s/Content/Meshes",unreal))
    os.make_directory_all(fmt.tprintf("%s/Content/Maps",unreal))
    _=os.write_entire_file(fmt.tprintf("%s/Levels.uproject",unreal),"{}")
    _=os.write_entire_file(fmt.tprintf("%s/Content/Meshes/SM_Fixture.uasset",unreal),unreal_quad())
    l:=fixture.level_begin("/Game/Maps/Room")
    mesh:=fixture.package_object(&l.w,"/Game/Meshes/SM_Fixture","/Script/Engine","StaticMesh","SM_Fixture")
    actor:=fixture.actor_add(&l,fixture.engine_class(&l.w,"StaticMeshActor"),"StaticMeshActor_0","Table")
    props:=fixture.bytes_make()
    fixture.object_property(&props,&l.w,"StaticMesh",mesh)
    root:=fixture.component_add(&l,actor,fixture.engine_class(&l.w,"StaticMeshComponent"),"StaticMeshComponent0",props)
    fixture.actor_set(&l,actor,root)
    level=fmt.tprintf("%s/Content/Maps/Room.umap",unreal)
    _=os.write_entire_file(level,fixture.level_bytes(&l))
    return
}

// The importer of maps claims a map and nothing else, and writes it as a
// scene of its project with the assets it names; importing it again writes
// the same scene where it is.
@(test)
an_unreal_map_imports_as_a_scene_of_its_project :: proc(t:^testing.T) {
    top,mirai,level:=unreal_level_folders("level")
    defer os.remove_all(top)
    maps:=unreal_maps_default().provider.source
    head,_:=os.read_entire_file(level,context.temp_allocator)
    testing.expect(t,maps.claims(level,head[:min(len(head),importer.SNIFF_BYTES)]),"a map is claimed")
    quad:=unreal_quad()
    testing.expect(t,!maps.claims(fmt.tprintf("%s/Unreal/Content/Meshes/SM_Fixture.uasset",top),quad[:min(len(quad),importer.SNIFF_BYTES)]),"a package is a model, not a map")
    scene:=fmt.tprintf("%s/assets/levels/Room.scene",mirai)
    for _ in 0..<2 {
        state:=new(Map_State)
        report,written,error:=maps.run(state,level,{root=mirai},context.allocator)
        maps.release(state,context.allocator)
        if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
        defer {importer.report_destroy(&report);delete(written)}
        slashed,_:=strings.replace_all(scene,"\\","/",context.temp_allocator)
        testing.expect_value(t,written,slashed)
        found:=false
        for entry in report.assets {if entry.kind==asset.KIND_SCENE {found=entry.path==slashed}}
        testing.expect(t,found,"the report lists the scene")
        testing.expect(t,len(report.assets)>1,"and the assets it names")
    }
}

// A real map: MIRAI_UNREAL_MAP into the project at MIRAI_UNREAL_PROJECT, with
// what it reports on the log. Without them it does not run.
@(test)
an_unreal_map_of_the_environment_imports :: proc(t:^testing.T) {
    level,has_level:=os.lookup_env("MIRAI_UNREAL_MAP",context.temp_allocator)
    project_root,has_project:=os.lookup_env("MIRAI_UNREAL_PROJECT",context.temp_allocator)
    if !has_level || !has_project {return}
    report,error:=unreal_scene.level_import(level,{root=project_root})
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer unreal_scene.level_report_destroy(&report)
    fmt.printfln("scene %s: %d entities, %d meshes, %.1f s",report.scene_path,report.entities,report.meshes,report.seconds)
    for c in report.classes {fmt.printfln("  %d/%d %s",c.translated,c.actors,c.class)}
    for warning in report.imports.warnings {fmt.printfln("warning: %s",warning)}
}

// A quad of an Unreal StaticMesh whose material moves its texture: a Surface
// program.
@(private="file")
moving_quad :: proc(top:string) -> string {
    unreal:=fmt.tprintf("%s/Unreal",top)
    for folder in ([?]string{"Meshes","M","T"}) {os.make_directory_all(fmt.tprintf("%s/Content/%s",unreal,folder))}
    _=os.write_entire_file(fmt.tprintf("%s/Levels.uproject",unreal),"{}")
    pixels:=make([]u8,4*4*4,context.temp_allocator)
    for &v,i in pixels {v=u8(i*13)}
    _=os.write_entire_file(fmt.tprintf("%s/Content/T/T_Albedo.uasset",unreal),fx.texture_package("/Game/T/T_Albedo","T_Albedo",pixels,4,4))
    p:=fx.package_make()
    flow:=fx.export(&p,fx.class(&p,"/Script/Engine","Material"),0,"M_Flow",nil)
    pan:=fx.writer(&p)
    fx.float_put(&pan,"SpeedX",0.1)
    panner:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionPanner"),flow,"Pan",fx.finish(&pan))
    sample:=fx.writer(&p)
    fx.object_put(&sample,"Texture",fx.external(&p,"/Game/T/T_Albedo","/Script/Engine","Texture2D","T_Albedo"))
    fx.input_put(&sample,"Coordinates","ExpressionInput",{expression=panner})
    moving:=fx.export(&p,fx.class(&p,"/Script/Engine","MaterialExpressionTextureSample"),flow,"Albedo",fx.finish(&sample))
    m:=fx.writer(&p)
    fx.input_put(&m,"BaseColor","ColorMaterialInput",{expression=moving,mask={true,true,true,false}})
    p.exports[flow-1].data=fx.finish(&m)
    _=os.write_entire_file(fmt.tprintf("%s/Content/M/M_Flow.uasset",unreal),fx.package_bytes(&p,"/Game/M/M_Flow"))
    up:=[3]f32{0,0,1}
    f:fixture.Mesh_Fixture
    f.layout=.Raw_Mesh
    f.positions=slice.clone([][3]f32{{0,0,0},{100,0,0},{100,100,0},{0,100,0}},context.temp_allocator)
    f.corners=slice.clone([]u32{0,2,1, 0,3,2},context.temp_allocator)
    f.normals=slice.clone([][3]f32{up,up,up,up,up,up},context.temp_allocator)
    f.uvs=slice.clone([][2]f32{{0,1},{1,0},{1,1},{0,1},{0,0},{1,0}},context.temp_allocator)
    f.groups=slice.clone([]u32{0,0},context.temp_allocator)
    f.smoothing=slice.clone([]u32{1,1},context.temp_allocator)
    f.slots=slice.clone([]fixture.Mesh_Slot{{name="Flow",imported_name="Flow",material="/Game/M/M_Flow"}},context.temp_allocator)
    path:=fmt.tprintf("%s/Content/Meshes/SM_Fixture.uasset",unreal)
    _=os.write_entire_file(path,fixture.static_mesh_package(f))
    return path
}

// Takes the import that runs when it ends, as the frames of the editor do.
@(private="file")
import_wait :: proc(s:^editor.Session) {
    for s.importer.running!=nil {
        editor.import_poll(s)
        time.sleep(time.Millisecond)
    }
}

// An import of this format that writes a Surface program asks the editor for
// the programs of the project to be published, so that its materials show
// without waiting for another change; one that writes none does not.
@(test)
an_import_that_writes_programs_publishes_the_programs_of_the_project :: proc(t:^testing.T) {
    top:=temp_folder("editor-import")
    defer os.remove_all(top)
    // No project file: the publication it asks for ends at once, and counts.
    root:=fmt.tprintf("%s/project",top)
    assets_root:=project.path(root,"assets",allocator=context.temp_allocator)
    os.make_directory_all(assets_root)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=assets_root,capacity=64})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    // The library in use gives the format of this plugin, as the editor finds it.
    storages:=[2]core.Storage_Info{
        {name="Unreal_Format",type=Unreal_Format,info=type_info_of(Unreal_Format),place=.Editor,plugin="unreal",default=proc(dst:rawptr) {(^Unreal_Format)(dst)^=unreal_format_default()}},
        {name="Unreal_Maps",type=Unreal_Maps,info=type_info_of(Unreal_Maps),place=.Editor,plugin="unreal",default=proc(dst:rawptr) {(^Unreal_Maps)(dst)^=unreal_maps_default()}},
    }
    info:=core.World_Info{storages=storages[:]}
    build:editor.Build_State
    importer:editor.Importer
    content:=new(editor.Content)
    defer free(content)
    s:=editor.Session{app=&app,build=&build,importer=&importer,content=content,info=&info,has_project=true,project_root=root,engine_root=top}
    source:=moving_quad(top)
    // The failure to publish is logged as an error; it is what is expected here.
    context.logger=log.nil_logger()
    defer editor.import_end(&s)
    if !testing.expectf(t,editor.import_file(&s,source),"%s",string(importer.message[:importer.message_length])) {return}
    // While it runs nothing else writes assets: another import and saving are refused, saying why.
    testing.expect(t,!editor.import_file(&s,source) && strings.contains(string(importer.message[:importer.message_length]),"is being imported"))
    testing.expect_value(t,editor.scene_save(&s),editor.Document_Error.Importing)
    import_wait(&s)
    testing.expect(t,importer.status.ok && !importer.status.importing && len(importer.written)>0,"the status says it ended and what it wrote")
    testing.expect(t,os.exists(fmt.tprintf("%s/shaders",root)),"the program is written into the shaders of the project")
    testing.expect(t,os.exists(fmt.tprintf("%s/models/Fixture",assets_root)),"into the folder its format says")
    testing.expect_value(t,build.programs.serial,u64(1))
    // Importing it again writes no program: the one there says the same.
    if !testing.expect(t,editor.import_file(&s,source)) {return}
    import_wait(&s)
    testing.expect_value(t,build.programs.serial,u64(1))
    delete(build.programs.message)
    // A map, whose bytes the format of packages reads too, is a map: it takes no folder.
    map_top,_,level:=unreal_level_folders("editor-map")
    defer os.remove_all(map_top)
    testing.expect(t,!editor.import_file(&s,level,folder="levels"),"a map is imported whole")
    testing.expect(t,strings.contains(string(importer.message[:importer.message_length]),"takes no folder"),string(importer.message[:importer.message_length]))
}
