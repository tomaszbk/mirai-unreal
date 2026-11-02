package unreal_scene

import uasset "project:plugins/unreal/editor/model"
import material "project:plugins/unreal/editor/material"
import render "mirai:engine/render"

// What stands for the content of /Engine a level names when no Unreal
// installation is mounted: the basic shapes of Unreal are the primitive
// shapes of Mirai, which have their size and place (a metre across, centred,
// the cone pointing up), and a material is the grid of Mirai
// (uasset.engine_grid), written with the materials the level keeps.

@(private="file",rodata)
BASIC_SHAPES:=[?]struct{path:string,shape:render.Shape}{
    {"/Engine/BasicShapes/Cube.Cube",.Cube},
    {"/Engine/BasicShapes/Sphere.Sphere",.Sphere},
    {"/Engine/BasicShapes/Cylinder.Cylinder",.Cylinder},
    {"/Engine/BasicShapes/Cone.Cone",.Cone},
    {"/Engine/BasicShapes/Plane.Plane",.Plane},
}

// The material the basic shapes of Unreal are drawn with.
BASIC_SHAPE_MATERIAL :: "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"

// The primitive shape that stands for a basic shape of Unreal at path, when
// no mount holds it.
engine_shape :: proc(c:^Context,path:string) -> (shape:render.Shape,ok:bool) {
    for basic in BASIC_SHAPES {
        if basic.path==path {
            if !engine_missing(c,path) {return}
            return basic.shape,true
        }
    }
    return
}

// Whether path names content of /Engine that no mount holds.
engine_missing :: proc(c:^Context,path:string) -> bool {
    library_lock(c)
    defer library_unlock(c)
    return uasset.engine_missing(c.lib,path)
}

// The translation of the material at path, or the grid that stands for it
// when it is of the engine, or reads content of the engine, and no mount
// holds that; ok is false, with a warning, when there is neither. custom:
// the PerInstanceSMCustomData of the instances it shows.
translation_or_grid :: proc(c:^Context,path:string,custom:[]f32=nil) -> (t:material.Translated_Material,ok:bool) {
    library_lock(c)
    defer library_unlock(c)
    unmounted :: "of Unreal's engine, which is not mounted (no Unreal installation): the grid of Mirai stands for it"
    if uasset.engine_missing(c.lib,path) {
        warn(c,"the material %s is %s",path,unmounted)
        return uasset.engine_grid(path),true
    }
    object,found:=material.object_find(c.lib,path)
    if !found {
        warn(c,"the material %s is not in its package; its slot keeps the material of its mesh",path)
        return
    }
    translated,error:=material.translate(c.lib,object,{reads=c.texture_reads[:],custom_data=custom},context.temp_allocator)
    if error.code!=.None {
        if missing:=uasset.engine_missing_named(c.lib,error.message);missing!="" {
            warn(c,"the material %s reads %s %s",path,missing,unmounted)
            return uasset.engine_grid(path),true
        }
        warn(c,"the material %s could not be translated (%s); its slot keeps the material of its mesh",path,error.message)
        return
    }
    if missing:=uasset.engine_missing_read(c.lib,&translated);missing!="" {
        material.translated_destroy(&translated)
        warn(c,"the material %s reads %s %s",path,missing,unmounted)
        return uasset.engine_grid(path),true
    }
    return translated,true
}
