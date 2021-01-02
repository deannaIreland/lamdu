let config = {
    packageOverrides = pkgs: rec {
        haskell = pkgs.haskell // {
            packages = pkgs.haskell.packages // {
                ghc8103 = pkgs.haskell.packages.ghc8103.override {
                    overrides = self: super: rec {
                        hsc2hs = pkgs.haskell.lib.unmarkBroken (haskell.lib.dontCheck super.hsc2hs);
                        freetype2 = self.callPackage ./nix/freetype2.nix {};
                        bindings-freetype-gl = self.callPackage ./nix/bindings-freetype-gl.nix {};
                        freetype-gl = self.callPackage ./nix/FreetypeGL.nix {};
                        graphics-drawingcombinators = self.callPackage ./nix/graphics-drawingcombinators.nix {};
                        hypertypes = self.callPackage ./nix/hypertypes.nix {};
                        lamdu-calculus = self.callPackage ./nix/lamdu-calculus.nix {};
                        nodejs-exec = self.callPackage ./nix/nodejs-exec.nix {};
                        language-ecmascript = self.callHackageDirect
                            { pkg = "language-ecmascript";
                              ver = "0.19.1.0";
                              sha256 = "0mbwz6m9666l7kmg934205gxw1627s3yzk4w9zkpr0irx7xqml5i";
                            } {};
                        testing-feat = self.callHackage "testing-feat" "1.1.0.0" {};
                    };
                };
            };
        };
    };
};
in with import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/641e5f572f1.tar.gz") {
    inherit config;
};

{
lamdu = pkgs.haskell.packages.ghc884.callPackage ./nix/lamdu.nix {};
}
