package write

import "core:mem"
import "core:slice"
import "core:sync"
import importer "mirai:cook/import"
import "mirai:cook/textures"
import "mirai:std/base"

// The textures an import built, each once: the same image built with the
// same options for another model (the materials of a level are imported
// with each package that shows them) is a copy of the first, which any
// thread takes or keeps holding the lock of the table.
Built_Textures :: struct {
    lock:sync.Mutex,
    by_key:map[Built_Key]^importer.Cooked_Texture,
    allocator:mem.Allocator, // of the table and its copies; any thread can call it
}

// What a texture is built from, as importer.Cooked_Texture holds it.
@(private)
Built_Key :: struct {size,hash,settings:u64}

built_init :: proc(t:^Built_Textures,allocator:mem.Allocator) {
    t^={allocator=allocator}
    t.by_key.allocator=allocator
}

// Lets go of every texture the table holds; nobody may use it at once.
built_destroy :: proc(t:^Built_Textures) {
    built_trim(t)
    delete(t.by_key)
}

// Lets go of the textures the table holds, holding its lock.
built_trim :: proc(t:^Built_Textures) {
    sync.mutex_lock(&t.lock)
    defer sync.mutex_unlock(&t.lock)
    for _,cooked in t.by_key {
        importer.cooked_texture_destroy(cooked)
        free(cooked,t.allocator)
    }
    clear(&t.by_key)
}

// Builds what model holds (importer.model_cook): of its textures, those the
// table holds are copies, and it keeps those built.
built_cook :: proc(t:^Built_Textures,model:^importer.Imported_Model,options:importer.Import_Options) {
    built_take(t,model,options)
    importer.model_cook(model,options)
    built_keep(t,model,options)
}

// Gives each image of model not built yet a copy of the texture the table
// holds for it, which importer.model_cook then takes as built.
@(private)
built_take :: proc(t:^Built_Textures,model:^importer.Imported_Model,options:importer.Import_Options) {
    settings:=importer.model_settings(model,options)
    holder:=base.dynamic_arena_allocator(model.arena) if model.arena!=nil else context.temp_allocator
    sync.mutex_lock(&t.lock)
    defer sync.mutex_unlock(&t.lock)
    if len(t.by_key)==0 {return}
    for &image in model.images {
        if image.cooked!=nil {continue}
        key,known:=built_key(image,settings)
        if !known {continue}
        held:=t.by_key[key]
        if held==nil {continue}
        cooked,error:=new(importer.Cooked_Texture,holder)
        if error!=nil {return}
        if !cooked_copy(held,cooked,t.allocator) {return}
        image.cooked=cooked
    }
}

// Keeps a copy of each texture of model built without an error that the
// table does not hold.
@(private)
built_keep :: proc(t:^Built_Textures,model:^importer.Imported_Model,options:importer.Import_Options) {
    settings:=importer.model_settings(model,options)
    for image in model.images {
        if image.cooked==nil || image.cooked.error!=.None {continue}
        if image.path!="" {continue}
        key:=Built_Key{image.cooked.size,image.cooked.hash,textures.settings_hash(importer.image_build_options(image,settings))}
        // Built Fast, it holds what the final texture is built with.
        if image.cooked.settings!=key.settings && image.cooked.final.settings!=key.settings {continue}
        sync.mutex_lock(&t.lock)
        _,held:=t.by_key[key]
        sync.mutex_unlock(&t.lock)
        if held {continue}
        cooked,error:=new(importer.Cooked_Texture,t.allocator)
        if error!=nil {return}
        if !cooked_copy(image.cooked,cooked,t.allocator) {
            free(cooked,t.allocator)
            return
        }
        sync.mutex_lock(&t.lock)
        _,held=t.by_key[key]
        kept:=false
        if !held {_,kept_error:=map_insert(&t.by_key,key,cooked);kept=kept_error==nil}
        sync.mutex_unlock(&t.lock)
        if !kept {
            importer.cooked_texture_destroy(cooked)
            free(cooked,t.allocator)
        }
    }
}

// The key of the texture of an image: false for an image of a file, which
// the table does not hold.
@(private)
built_key :: proc(image:importer.Imported_Image,settings:importer.Import_Settings) -> (key:Built_Key,ok:bool) {
    if image.path!="" {return}
    bytes:=image.made.texels if image.made.width>0 else image.data
    return {u64(len(bytes)),base.hash64(bytes),textures.settings_hash(importer.image_build_options(image,settings))},true
}

// A copy of from in to, in an arena of its own over parent.
@(private)
cooked_copy :: proc(from,to:^importer.Cooked_Texture,parent:mem.Allocator) -> bool {
    to^={settings=from.settings,final=from.final,size=from.size,hash=from.hash,built=from.built,error=from.error}
    mem.dynamic_arena_init(&to.arena,parent,parent,block_size=1<<20,out_band_size=1<<20)
    allocator:=base.dynamic_arena_allocator(&to.arena)
    to.built.allocator=allocator
    error:mem.Allocator_Error
    if to.built.mips,error=make([][]u8,len(from.built.mips),allocator);error!=nil {
        importer.cooked_texture_destroy(to)
        return false
    }
    for level,i in from.built.mips {
        if to.built.mips[i],error=slice.clone(level,allocator);error!=nil {
            importer.cooked_texture_destroy(to)
            return false
        }
    }
    return true
}
