package fixture

import "core:strings"
import unreal "project:plugins/unreal/editor/package"

@(private="file")
LANDSCAPE_RELEASE :: [4]u32{0x9c54d522,0xa8264fbe,0x94210746,0x61b482d0}

// The height Unreal keeps for vertex (x,y) of landscape_map: x+10y local units.
landscape_height :: proc(x,y:int) -> int {return 32768+128*(x+10*y)}

// A landscape of two components side by side, two quads each in two
// subsections of one quad, one heightmap shared, a weightmap each with a
// paint layer and the visibility layer; the actor at scale, writing the
// runtime virtual textures of the packages virtual_textures.
landscape_map :: proc(scale:=[3]f32{100,100,50},virtual_textures:=[]string{}) -> unreal.Package {
    b:=builder_make()
    custom_version(&b,LANDSCAPE_RELEASE,3)
    world:=export_begin(&b,class_import(&b,"/Script/Engine","World"),0,"Map")
    properties_end(&b);export_end(&b)
    heights:=make([]u8,8*4*4,context.temp_allocator)
    for component in 0..<2 {
        base:=component*2
        for ty in 0..<4 {for tx in 0..<4 {
            // Subsections of one quad: texels 1 and 2 both hold vertex 1.
            vx:=tx<2?tx:tx-1
            vy:=ty<2?ty:ty-1
            h:=landscape_height(base+vx,vy)
            at:=((component*4+tx)+ty*8)*4
            heights[at],heights[at+1],heights[at+2],heights[at+3]=0,u8(h&255),u8(h>>8),0
        }}
    }
    heightmap:=texture_export(&b,0,"Heightmap",8,4,heights)
    weightmaps:[2]unreal.Object_Ref
    for component in 0..<2 {
        pixels:=make([]u8,4*4*4,context.temp_allocator)
        for ty in 0..<4 {for tx in 0..<4 {
            vx:=component*2+(tx<2?tx:tx-1)
            vy:=ty<2?ty:ty-1
            grass:=u8(vx==0?0:255)
            hole:=u8(vx==3 && vy==0?255:0)
            at:=(tx+ty*4)*4
            // BGRA: the grass in R (channel 0), the visibility in G (channel 1).
            pixels[at],pixels[at+1],pixels[at+2],pixels[at+3]=0,hole,grass,0
        }}
        weightmaps[component]=texture_export(&b,0,component==0?"Weightmap0":"Weightmap1",4,4,pixels)
    }
    level_ref:=export_begin(&b,class_import(&b,"/Script/Engine","Level"),world,"PersistentLevel")
    properties_end(&b)
    put_u32(&b,0);put_u32(&b,1)
    actors_at:=len(b.bytes)
    put_u32(&b,0)
    export_end(&b)
    shared:=package_import(&b,"/Game/Map_sharedassets/Grass_LayerInfo")
    grass:=object_import(&b,shared,"/Script/Landscape","LandscapeLayerInfoObject","Grass_LayerInfo")
    engine:=package_import(&b,"/Engine/EngineResources/LandscapeVisibilityLayerInfo")
    visibility:=object_import(&b,engine,"/Script/Landscape","LandscapeLayerInfoObject","LandscapeVisibilityLayerInfo")
    material_package:=package_import(&b,"/Game/M_Ground")
    material:=object_import(&b,material_package,"/Script/Engine","Material","M_Ground")
    actor:=export_begin(&b,class_import(&b,"/Script/Landscape","Landscape"),level_ref,"Landscape")
    guid_property(&b,"LandscapeGuid",{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16})
    object_property(&b,"LandscapeMaterial",material)
    if len(virtual_textures)>0 {
        refs:=make([]unreal.Object_Ref,len(virtual_textures),context.temp_allocator)
        for path,i in virtual_textures {
            refs[i]=object_import(&b,package_import(&b,path),"/Script/Engine","RuntimeVirtualTexture",path[strings.last_index_byte(path,'/')+1:])
        }
        objects_property(&b,"RuntimeVirtualTextures",refs)
    }
    root_at:=len(b.bytes)
    object_property(&b,"RootComponent",0)
    properties_end(&b);export_end(&b)
    root:=export_begin(&b,class_import(&b,"/Script/Engine","SceneComponent"),actor,"RootComponent0")
    vector_property(&b,"RelativeLocation","Vector",{1000,2000,300})
    vector_property(&b,"RelativeScale3D","Vector",scale)
    properties_end(&b);export_end(&b)
    component_class:=class_import(&b,"/Script/Landscape","LandscapeComponent")
    for component in 0..<2 {
        _=export_begin(&b,component_class,actor,component==0?"LandscapeComponent_0":"LandscapeComponent_1")
        if component==1 {int_property(&b,"SectionBaseX",2)}
        int_property(&b,"ComponentSizeQuads",2)
        int_property(&b,"SubsectionSizeQuads",1)
        int_property(&b,"NumSubsections",2)
        vector4_property(&b,"HeightmapScaleBias",{1.0/8,1.0/4,component==0?0:0.5,0})
        object_property(&b,"HeightmapTexture",heightmap)
        allocations:=structs_begin(&b,"WeightmapLayerAllocations","WeightmapLayerAllocationInfo",2)
        for info,channel in ([2]unreal.Object_Ref{grass,visibility}) {
            object_property(&b,"LayerInfo",info)
            byte_property(&b,"WeightmapTextureChannel",u8(channel))
            element_end(&b)
        }
        structs_end(&b,allocations)
        objects_property(&b,"WeightmapTextures",{weightmaps[component]})
        object_property(&b,"AttachParent",root)
        properties_end(&b);export_end(&b)
    }
    patch_u32(&b,actors_at,u32(actor))
    patch_u32(&b,root_at+25,u32(root))
    return package_of(&b,"/Game/Map")
}

