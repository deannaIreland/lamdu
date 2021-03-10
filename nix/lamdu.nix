{ mkDerivation, aeson, aeson-diff, aeson-pretty, ansi-wl-pprint, base
, base-compat, base16-bytestring, binary, bytestring
, Cabal, constraints, containers, cryptohash-sha256, data-default, deepseq
, directory, edit-distance, ekg-core
, executable-path, filepath, generic-data, GLFW-b
, graphics-drawingcombinators, hashable, HUnit, lamdu-calculus, momentu
, language-ecmascript, lattices, lens, lens-aeson, leveldb-haskell, List, mtl
, nodejs-exec, OpenGL, optparse-applicative, pretty, process
, random, safe-exceptions, split, StateVar, stdenv, hypertypes
, template-haskell, temporary, test-framework, test-framework-hunit
, text, time, timeit, transformers
, unicode-properties, unordered-containers, uuid, uuid-types, vector, yaml
, zip-archive, lib, gitMinimal
}:
mkDerivation {
  pname = "Lamdu";
  version = "0.1";
  src =
      let src = ../.;
          myFilter =
              path: type:
              let relPath = lib.removePrefix (toString src + "/") (toString path);
              in
              let res =
              !lib.any (prefix: lib.hasPrefix prefix relPath)
              [ "dist" # cabal
                "dist-newstyle" # cabal-new
                ".stack-work" # stack builds
                "ghci-out" # ghci loads
                "git-cache" # git caches
                "result" # nix output
              ];
              in res;
      in lib.cleanSource (lib.cleanSourceWith { filter = myFilter; inherit src; });
  configureFlags = [ "-f-ekg" ];
  isLibrary = true;
  isExecutable = true;
  doHaddock = false;
  enableLibraryProfiling = false;
  enableExecutableProfiling = false;
  enableSeparateDataOutput = true;
  libraryHaskellDepends = [
    aeson aeson-pretty ansi-wl-pprint base base-compat
    base16-bytestring binary bytestring constraints containers cryptohash-sha256
    data-default deepseq directory edit-distance generic-data
    ekg-core executable-path filepath GLFW-b
    graphics-drawingcombinators hashable lamdu-calculus momentu
    language-ecmascript lattices lens lens-aeson leveldb-haskell List mtl
    nodejs-exec OpenGL optparse-applicative pretty process random
    safe-exceptions split StateVar hypertypes temporary text time timeit
    transformers unicode-properties unordered-containers uuid uuid-types vector
    zip-archive
  ];
  buildDepends = [ gitMinimal ];
  executableHaskellDepends = [
    base base-compat directory process template-haskell time
  ];
  testHaskellDepends = [
    aeson aeson-diff aeson-pretty base bytestring Cabal
    containers deepseq directory filepath
    GLFW-b HUnit lamdu-calculus momentu lens lens-aeson List mtl
    nodejs-exec pretty process random split hypertypes test-framework
    test-framework-hunit text uuid-types
    yaml
  ];
  homepage = "http://www.lamdu.org";
  description = "A next generation IDE";
  license = "GPL";
}
