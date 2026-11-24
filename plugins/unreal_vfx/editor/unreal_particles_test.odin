package unreal_vfx_editor

import "core:testing"
import fixture "project:plugins/unreal/editor/fixture/files"
import "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import "plugins:vfx/runtime/effect"

// A curve of Unreal with more keys than an effect keeps is sampled at evenly
// spread times, and one that fits keeps its keys; the curves of several
// modules multiply, at the keys of all.
@(test)
unreal_curves_keep_their_keys_or_their_shape :: proc(t:^testing.T) {
    d:Dist
    for i in 0..<3 {d.times[i],d.values[i]=f32(i)*0.5,{f32(i),0,0}}
    d.key_count=3
    c:=life_curve({d})
    testing.expect(t,c.times[0]==0 && c.times[1]==0.5 && c.times[2]==1 && c.values[2]==2 && c.values[7]==2)
    half:=Dist{min={0.5,0.5,0.5},max={0.5,0.5,0.5},found=true}
    ramp:Dist
    ramp.times[0],ramp.times[1],ramp.values[0],ramp.values[1],ramp.key_count=0.25,0.75,{1,1,1},{3,3,3},2
    c=life_curve({d,half,ramp})
    testing.expectf(t,c.times[0]==0 && c.times[1]==0.25 && c.times[2]==0.5 && c.times[3]==0.75 && c.times[4]==1,"%v",c.times)
    testing.expectf(t,c.values[1]==0.5*0.5*1 && c.values[2]==1*0.5*2 && c.values[4]==2*0.5*3,"%v",c.values)
    for i in 0..<20 {d.times[i],d.values[i]=f32(i)/19,{f32(i)/19*4,0,0}}
    d.key_count=20
    c=life_curve({d})
    for i in 0..<effect.PARTICLE_CURVE_KEYS {
        testing.expectf(t,abs(c.values[i]-c.times[i]*4)<1e-4,"key %d of a line: %v at %v",i,c.values[i],c.times[i])
    }
    testing.expect(t,dist_at(d,2)=={4,0,0} && dist_at(d,-1)=={0,0,0})
}

// Colors of Unreal above one give their peak to the intensity of the effect.
@(test)
unreal_colors_above_one_go_to_the_intensity :: proc(t:^testing.T) {
    info:=UNREAL_PARTICLE_DEFAULTS
    colors_set(&info,{4,2,0,1},{1,1,1,2})
    testing.expect(t,info.intensity==4)
    testing.expect(t,info.colors[0]=={1,0.5,0,1} && info.colors[1]=={0.25,0.25,0.25,1})
    testing.expect(t,effect.particle_validate({info=info}).message=="")
}

// BlendMode maps Additive, Modulate and Translucent to Additive, Multiply and Alpha.
@(test)
material_look_maps_additive_and_modulate_blends :: proc(t:^testing.T) {
    Case :: struct {mode,shading:string,want:effect.Particle_Blend,lit:bool}
    cases:=[?]Case{
        {"BLEND_Additive","MSM_Unlit",.Additive,false},
        {"BLEND_Modulate","MSM_Unlit",.Multiply,false},
        {"BLEND_Translucent","MSM_DefaultLit",.Alpha,true},
    }
    for c in cases {
        w:=fixture.writer_make({package_name="/Game/FX/M_Look"})
        props:=fixture.bytes_make()
        fixture.enum_property(&props,&w,"BlendMode","EBlendMode",c.mode)
        fixture.enum_property(&props,&w,"ShadingModel","EMaterialShadingModel",c.shading)
        fixture.none(&props,&w)
        fixture.put_u32(&props,0)
        mat:=fixture.export_add(&w,{class=fixture.engine_class(&w,"Material"),name="M_Look",data=props.data[:]})
        p,err:=unreal.package_open(fixture.package_bytes(&w),context.temp_allocator)
        if !testing.expect_value(t,err.code,unreal.Error_Code.None) {continue}
        lib:level.Library
        level.library_init(&lib,nil,context.temp_allocator)
        idx,_:=level.library_add(&lib,"/Game/FX/M_Look",&p)
        d:=level.Document{library=&lib,allocator=context.temp_allocator}
        d.properties.allocator,d.templates.allocator,d.by_ref.allocator=context.temp_allocator,context.temp_allocator,context.temp_allocator
        blend,lit:=material_look(&d,{i32(idx),unreal.Object_Ref(mat)})
        testing.expectf(t,blend==c.want && lit==c.lit,"%s/%s: got %v lit=%v",c.mode,c.shading,blend,lit)
    }
}

// Non-uniform Niagara sprite and mesh sizes preserve per-axis ratios in Particle_Info.scale.
@(test)
niagara_non_uniform_size_sets_particle_scale :: proc(t:^testing.T) {
    v:Niagara_Values
    v.values=make([dynamic]Niagara_Value,context.temp_allocator)
    v.switches=make([dynamic]Niagara_Switch,context.temp_allocator)
    append(&v.switches,Niagara_Switch{"InitializeParticle.Sprite Size Mode","Non-Uniform"})
    append(&v.values,Niagara_Value{key="InitializeParticle.Sprite Size",values={0=20,1=10},count=2})
    info:=UNREAL_PARTICLE_DEFAULTS
    switched:=make([dynamic]string,context.temp_allocator)
    niagara_size(&v,&info,"Sprite Size","Uniform Sprite Size","Sprite Size",1,&switched)
    testing.expectf(t,abs(info.size[0]-0.2)<1e-5 && abs(info.scale.x-1)<1e-5 && abs(info.scale.y-0.5)<1e-5,"%v %v",info.size,info.scale)

    clear(&v.switches);clear(&v.values)
    append(&v.switches,Niagara_Switch{"InitializeParticle.Mesh Scale Mode","Non-Uniform"})
    // Unreal (X=1, Y=2, Z=4) -> Mirai (X=2, Y=4, Z=1), peak 4 -> scale (0.5, 1, 0.25).
    append(&v.values,Niagara_Value{key="InitializeParticle.Mesh Scale",values={0=1,1=2,2=4},count=3})
    info=UNREAL_PARTICLE_DEFAULTS
    niagara_size(&v,&info,"Mesh Scale","Mesh Uniform Scale","Mesh Scale",100,&switched)
    testing.expectf(t,abs(info.size[0]-4)<1e-5 && abs(info.scale.x-0.5)<1e-5 && abs(info.scale.y-1)<1e-5 && abs(info.scale.z-0.25)<1e-5,"%v %v",info.size,info.scale)
}
