package unreal_scene

import "core:strings"
import importer "mirai:cook/import"
import "project:plugins/unreal/editor/landscape"
import "project:plugins/unreal/editor/level"
import material "project:plugins/unreal/editor/material"

// The runtime virtual textures the landscapes of a level write, each with
// the material of its landscape and where the landscape is: what the
// materials of the level read of them (material.Options.writers). A texture
// written by two landscapes is read from the first.
virtual_texture_writers :: proc(c:^Context) -> []material.Virtual_Texture_Writer {
    d:=c.d
    writers:=make([dynamic]material.Virtual_Texture_Writer,context.temp_allocator)
    for i in landscape.landscape_actors(d) {
        actor:=d.actors[i]
        textures:=level.paths_of(d,actor.ref,"RuntimeVirtualTextures")
        material_path:=level.path_of(d,actor.ref,"LandscapeMaterial")
        if len(textures)==0 || material_path=="" {continue}
        world,_,world_error:=level.actor_world(d,i)
        if world_error.code!=.None {continue}
        for texture in textures {
            if texture=="" {continue}
            taken:=false
            for w in writers {taken||=strings.equal_fold(w.texture,texture)}
            if taken {
                importer.output_warn(&c.outputs,"%s: %s writes the virtual texture %s, which another landscape writes; what reads it sees the first",c.source,actor.label,texture)
                continue
            }
            append(&writers,material.Virtual_Texture_Writer{texture=texture,material=material_path,coordinates=landscape.coordinates_of(world)})
        }
    }
    return writers[:]
}
