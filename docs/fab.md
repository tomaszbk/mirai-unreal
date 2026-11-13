# Fab: the library of the account in the editor

`editor/fab` (imported as `fab`) talks to Fab with the Epic account of the user, and `fab.odin`
and `fab_api.odin` put it in the editor: the Fab panel under View and the `unreal.fab.*` methods,
which `mirai rpc` and MCP reach. A listing comes into a folder of the assets and what it brings is
imported as it lands.

## Workflow

1. **Sign in.** `unreal.fab.sign_in` (or the panel's button) opens an Epic page in the browser and
   waits until the user signs in there and accepts; nothing is copied back. The page is that of a
   device code, and the session it gives is traded for one of the client Fab takes. That session
   is kept in the configuration folder of the user (`mirai/epic-session.json`, readable only by
   the user) and its access renews itself with its refresh token; `unreal.fab.sign_out` ends it
   at Epic, so that its tokens stop working wherever they are, and forgets it.
2. **Library.** `unreal.fab.library` reads the listings the account owns in the Unreal format.
3. **Contents.** `unreal.fab.contents` gives, for a listing, the files of its build in the Unreal
   format under its `Content` folder (the build of the newest engine, or the one `version` names),
   and its other formats with their files.
4. **Download.** `unreal.fab.download` brings into `folder`:
   - of the Unreal format, the `picks` (files or folders under `Content`) with the packages they
     read, or the whole build without picks; each package goes to its path under `/Game` inside
     the folder, as a map that is brought does. Then the maps and the packages of meshes picked are
     imported (of a whole build its maps, or its meshes when it has none);
   - of another format, the `file` of a `format`, unpacked when it is a zip, and its models
     imported.

   The method waits, within `seconds`, for the download and then for the imports it gave, one
   after the other; past that it answers `importing` and they go on.

The panel does the same: a listing of the filtered library, its Unreal files with a checkbox each
or a file of another format, and the folder.

## How a download works

- A build is a manifest (the files, each made of parts of chunks) and its chunks, under the folder
  of the manifest on the content service. Only the chunks of the files wanted are fetched, at once
  and several in parallel, and each file is put together and checked against the hash of the
  manifest. A chunk is shared by small files, so a pick fetches a little more than its bytes.
- A file of another format comes from the address Fab gives for it: the file itself, or the
  manifest of a build of it, which then downloads as above.
- The packages a pick reads come round by round: the walk of `scene.packages_walk`, the one that
  finds what a map reads on disk, asks the build for each round of names together, so a map comes
  with its meshes, materials, textures and the packages World Partition keeps apart, and without
  its build data.
- Requests go through the system's `curl`; what they carry goes in a config file of a temporary
  folder, never on the command line. The chunks wait in `.mirai/tmp/fab` of the project and are
  removed once the download ends.
- One job runs at a time, in its own thread; a method waits for it up to `seconds` and otherwise
  answers what it is doing (`unreal.fab.status`). Every method first takes the job that ended: an
  editor without a window runs no frames between calls.
- Each file is written once, part after part, and hashed as it is written; a chunk is held only
  while it is decoded.

## Invariants

- The session never goes into a project or a message, and no address with a signature goes into
  a message (`url_shown`).
- What the service gives is untrusted: a name that leaves its folder, a size past the limits or a
  hash that does not match refuses the download with a message, never a crash.
- The other formats keep the folders of their archive inside the folder given.

## Verification

- `mirai test plugins/unreal/editor/fab`: manifests, chunks and archives, valid and damaged, and
  a pick of a map that downloads only it and what it reads, from a build served by `file://`.
- Against Fab, in a session of a project with the plugin: `unreal.fab.sign_in`, `library`,
  `contents` and a `download` of a pick and of a file of another format.
