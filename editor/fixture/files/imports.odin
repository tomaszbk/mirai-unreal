package fixture_files

import "core:fmt"
import importer "mirai:cook/import"
import "mirai:store"

// The store of the imports of a test into the project at root, under its
// .mirai folder; nil when it does not open. store_close closes it.
store_open :: proc(root:string) -> ^store.Store {
    s:=new(store.Store)
    opened,error:=store.open(fmt.tprintf("%s/.mirai/store",root))
    if error!=.None {
        free(s)
        return nil
    }
    s^=opened
    return s
}

store_close :: proc(s:^store.Store) {
    if s==nil {return}
    store.close(s)
    free(s)
}

// options of an import into the project at root as the library gives them:
// its package in s and its documents in the assets of root.
into :: proc(root:string,s:^store.Store,options:=importer.Import_Options{}) -> importer.Import_Options {
    options:=options
    options.root,options.store,options.documents=root,s,fmt.tprintf("%s/assets",root)
    return options
}
