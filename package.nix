{
  lib,
  buildHelixPlugin,
}:
buildHelixPlugin {
  pname = "inline-values.hx";
  version = "0.0.1";

  # The cog is the repo itself, but only the files steel actually loads are in
  # the source set -- mirroring the builder's install step, which globs
  # `**/*.scm`. Editing the README therefore does not force a rebuild of every
  # consumer.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "scm") ./.;
  };

  # No pluginDependencies: the plugin only talks to the editor. If one is
  # added, keep this list in step with cog.scm's `dependencies`.

  doSteelCheck = true;

  meta = {
    description = "Debugger values drawn inline in the Helix editor while stopped";
    homepage = "https://github.com/apetrovic6/inline-values.hx";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
