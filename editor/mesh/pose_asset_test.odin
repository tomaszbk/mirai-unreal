package mesh

import "core:math"
import "core:testing"
import unreal "project:plugins/unreal/editor/package"
import "project:plugins/unreal/editor/fixture"

@(private="file")
Pose_Fixture :: struct {
    additive:bool,
    base_pose:i32,
    names:[]string,  // a pose per name
    tracks:[]string,
    curves:[]string,
    values:[][]f32,  // by pose, by curve
    no_source:bool,  // the poses keep no source pose
    poses:int,       // poses written; 0: one per name
}

// A PoseAsset whose pose k moves track t by (k+1, t, 0) cm and turns it about Z.
@(private="file")
pose_fixture :: proc(f:Pose_Fixture) -> unreal.Package {
    b:=fixture.builder_make()
    skeleton:=fixture.object_import(&b,fixture.package_import(&b,"/Game/Figure"),"/Script/Engine","Skeleton","Figure")
    asset:=fixture.export_begin(&b,fixture.class_import(&b,"/Script/Engine","PoseAsset"),0,"PA_Face")
    fixture.object_property(&b,"Skeleton",skeleton)
    fixture.bool_property(&b,"bAdditivePose",f.additive)
    fixture.int_property(&b,"BasePoseIndex",f.base_pose)
    container:=fixture.struct_begin(&b,"PoseContainer","PoseDataContainer")
    names :: proc(b:^fixture.Builder,property:string,values:[]string) {
        at:=fixture.tag_begin(b,property,"ArrayProperty","NameProperty")
        fixture.put_u32(b,u32(len(values)))
        for value in values {fixture.put_name(b,value)}
        fixture.tag_end(b,at)
    }
    names(&b,"PoseFNames",f.names)
    names(&b,"Tracks",f.tracks)
    count:=f.poses if f.poses>0 else len(f.names)
    poses:=fixture.structs_begin(&b,"Poses","PoseData",count)
    for k in 0..<count {
        if !f.no_source {
            transforms:=fixture.structs_begin(&b,"SourceLocalSpacePose","Transform",len(f.tracks))
            for t in 0..<len(f.tracks) {
                turn:=animation_turn(f32(k+1)*.1)
                at:=fixture.tag_begin(&b,"Rotation","StructProperty","Quat");for c in turn {fixture.put_f32(&b,c)};fixture.tag_end(&b,at)
                fixture.vector_property(&b,"Translation","Vector",{f32(k+1),f32(t),0})
                fixture.vector_property(&b,"Scale3D","Vector",{1,1,1})
                fixture.element_end(&b)
            }
            fixture.structs_end(&b,transforms)
        }
        if k<len(f.values) {
            at:=fixture.tag_begin(&b,"SourceCurveData","ArrayProperty","FloatProperty")
            fixture.put_u32(&b,u32(len(f.values[k])))
            for value in f.values[k] {fixture.put_f32(&b,value)}
            fixture.tag_end(&b,at)
        }
        fixture.element_end(&b)
    }
    fixture.structs_end(&b,poses)
    if len(f.curves)>0 {
        curves:=fixture.structs_begin(&b,"Curves","AnimCurveBase",len(f.curves))
        for curve in f.curves {fixture.name_property(&b,"CurveName",curve);fixture.element_end(&b)}
        fixture.structs_end(&b,curves)
    }
    fixture.struct_end(&b,container)
    fixture.properties_end(&b)
    fixture.export_end(&b)
    _=asset
    return fixture.package_of(&b,"/Game/PA_Face")
}

@(private="file")
animation_turn :: proc(angle:f32) -> [4]f32 {return {0,0,math.sin(angle/2),math.cos(angle/2)}}

@(private="file")
pose_read :: proc(p:unreal.Package) -> (a:Animation,error:unreal.Error) {
    p:=p
    for _,i in p.exports {if pose_asset_is(&p,i) {return pose_asset_read(&p,i)}}
    return {},{.Invalid_Reference,0,"no pose asset"}
}

@(test)
a_pose_asset_is_a_frame_per_pose_after_its_base_with_its_names_and_curves :: proc(t:^testing.T) {
    f:=Pose_Fixture{additive=true,base_pose=0,names={"base","jaw_open","blink"},tracks={"root","jaw"},curves={"jawOpen"},values={{0},{.8},{0}}}
    a,error:=pose_read(pose_fixture(f))
    defer animation_destroy(&a)
    if !testing.expectf(t,error.code==.None,"%v",error) {return}
    testing.expect(t,a.skeleton!="" && !a.rest_first && a.step && a.keys==4 && len(a.tracks)==2 && len(a.markers)==3)
    testing.expect(t,a.markers[1].name=="jaw_open" && abs(a.markers[1].time-2*POSE_ASSET_INTERVAL)<1e-6)
    jaw:=a.tracks[1]
    testing.expect(t,jaw.name=="jaw" && jaw.positions[0]==jaw.positions[1] && jaw.positions[2]==[3]f32{2,1,0},"the base of an additive is its base pose; frame k+1 is pose k")
    if testing.expect(t,len(a.curves)==1 && len(a.curves[0].keys)==4) {
        testing.expect(t,a.curves[0].name=="jawOpen" && a.curves[0].keys[0].value==0 && a.curves[0].keys[2].value==.8 && a.curves[0].keys[2].interpolation==.Constant)
    }
    // Another asset, or an additive without a base, asks for the pose at rest first.
    f.additive=false
    b,_:=pose_read(pose_fixture(f))
    testing.expect(t,b.rest_first && b.tracks[1].positions[0]==[3]f32{} && b.tracks[1].rotations[0]==[4]f32{0,0,0,1})
    animation_destroy(&b)
}

@(test)
pose_assets_that_do_not_add_up_or_are_damaged_are_refused :: proc(t:^testing.T) {
    good:=Pose_Fixture{additive=true,names={"base","smile"},tracks={"root"},curves={"smile"},values={{0},{1}}}
    nan:=f32(0);nan/=nan
    cases:=[?]struct{f:Pose_Fixture,why:string}{
        {Pose_Fixture{names={"a","b"},tracks={"root"},poses=1},"fewer poses than names"},
        {Pose_Fixture{names={"a"},tracks={"root"},no_source=true},"no source pose"},
        {Pose_Fixture{names={"a"},tracks={"root"},curves={"c"},values={{nan}}},"a curve value that is not finite"},
        {Pose_Fixture{names={"a"},tracks={"root"},curves={"c","d"},values={{1}}},"fewer values than curves"},
        {Pose_Fixture{tracks={"root"}},"no poses"},
    }
    for c in cases {
        a,error:=pose_read(pose_fixture(c.f))
        testing.expectf(t,error.code!=.None,"refused: %s",c.why)
        animation_destroy(&a)
    }
    // Cut at any length or with a byte changed, it is read or refused: never a crash or a leak.
    p:=pose_fixture(good)
    bytes:=p.bytes
    for cut in 0..<len(bytes) {
        damaged:=p;damaged.bytes=bytes[:cut]
        a,_:=pose_read(damaged)
        animation_destroy(&a)
    }
    changed:=make([]u8,len(bytes),context.temp_allocator)
    for at in 0..<len(bytes) {
        copy(changed,bytes)
        changed[at]~=0x5a
        damaged:=p;damaged.bytes=changed
        a,_:=pose_read(damaged)
        animation_destroy(&a)
    }
}
