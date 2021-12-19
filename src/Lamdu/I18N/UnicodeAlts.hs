module Lamdu.I18N.UnicodeAlts (unicodeAlts) where

import qualified Data.Text as Text
import           Lamdu.Prelude

-- | Alternative ways to enter texts with non-ascii characters which
-- may be difficult to type on standard keyboard layouts.
unicodeAlts :: Text -> [Text]
unicodeAlts haystack =
    traverse alts (Text.unpack haystack)
    <&> concat
    <&> Text.pack
    where
        alts x = [x] : extras x
        extras '≥' = [">="]
        extras '≤' = ["<="]
        extras '≠' = ["/=", "!=", "<>"]
        extras '⋲' = ["<{"]
        extras _ = []
