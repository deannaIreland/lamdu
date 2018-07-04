{-# LANGUAGE FlexibleContexts #-}
module Lamdu.GUI.ExpressionEdit.HoleEdit.ValTerms
    ( expr
    , binderContent
    , allowedSearchTermCommon
    , allowedFragmentSearchTerm
    , getSearchStringRemainder
    , verifyInjectSuffix
    , definitePart
    ) where

import qualified Control.Lens as Lens
import qualified Data.Char as Char
import           Data.Property (Property)
import qualified Data.Property as Property
import qualified Data.Text as Text
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import qualified Lamdu.Builtins.Anchors as Builtins
import qualified Lamdu.CharClassification as Chars
import           Lamdu.Formatting (Format(..))
import           Lamdu.Name (Name(..), Collision(..))
import qualified Lamdu.Name as Name
import qualified Lamdu.Sugar.Lens as SugarLens
import           Lamdu.Sugar.Types

import           Lamdu.Prelude

collisionText :: Name.Collision -> Text
collisionText NoCollision = ""
collisionText (Collision i) = Text.pack (show i)
collisionText UnknownCollision = "?"

ofName :: Name o -> [Text]
ofName Name.Unnamed{} = []
ofName (Name.AutoGenerated text) = [text]
ofName (Name.Stored storedName) =
    [ displayName
        <> collisionText textCollision
        <> collisionText (storedName ^. Name.snTagCollision)
    ]
    where
        Name.TagText displayName textCollision = storedName ^. Name.snDisplayText

formatProp :: Format a => Property m a -> Text
formatProp i = i ^. Property.pVal & format

formatLiteral :: Literal (Property m) -> Text
formatLiteral (LiteralNum i) = formatProp i
formatLiteral (LiteralText i) = formatProp i
formatLiteral (LiteralBytes i) = formatProp i

expr :: Monad i => Expression (Name o) i o a -> [Text]
expr (Expression _ body_) =
    case body_ of
    BodyLam {} -> ["lambda", "\\", "Λ", "λ", "->", "→"]
    BodySimpleApply x -> "apply" : foldMap expr x
    BodyLabeledApply x ->
        "apply"
        : ofName (x ^. aFunc . val . bvNameRef . nrName)
        ++ (x ^.. aAnnotatedArgs . Lens.folded . aaTag . tagName >>= ofName)
    BodyRecord {} ->
        -- We don't allow completing a record by typing one of its
        -- field names/vals
        ["{}", "()", "[]"]
    BodyGetField gf ->
        ofName (gf ^. gfTag . tagInfo . tagName) <&> ("." <>)
    BodyCase cas ->
        ["case", "of"] ++
        case cas of
            Case LambdaCase (Composite [] ClosedComposite{} _) -> ["absurd"]
            _ -> []
    BodyIfElse {} -> ["if", ":"]
    -- An inject "base expr" can have various things in its val filled
    -- in, so the result group based on it may have both nullary
    -- inject (".") and value inject (":"). Thus, an inject must match
    -- both.
    -- So these terms are used to filter the whole group, and then
    -- isExactMatch (see below) is used to filter each entry.
    BodyInject (Inject tag _) ->
        (<>) <$> ofName (tag ^. tagInfo . tagName) <*> [":", "."]
    BodyLiteral i -> [formatLiteral i]
    BodyGetVar GetParamsRecord {} -> ["Params"]
    BodyGetVar (GetParam x) -> ofName (x ^. pNameRef . nrName)
    BodyGetVar (GetBinder x) -> ofName (x ^. bvNameRef . nrName)
    BodyToNom (Nominal tid binder) ->
        ofName (tid ^. tidName)
        ++ expr (binder ^. bContent . SugarLens.binderContentResultExpr)
    BodyFromNom (Nominal tid _) ->
        ofName (tid ^. tidName) <>
        -- The hole's "extra" apply-form results will be an
        -- IfElse, but we give val terms only to the base expr
        -- which looks like this:
        ["if" | tid ^. tidTId == Builtins.boolTid]
    BodyHole {} -> []
    BodyFragment {} -> []
    BodyPlaceHolder {} -> []

binderContent :: Monad i => BinderContent (Name o) i o a -> [Text]
binderContent BinderLet{} = ["let"]
binderContent (BinderExpr x) = expr x

type Suffix = Char

allowedSearchTermCommon :: [Suffix] -> Text -> Bool
allowedSearchTermCommon suffixes searchTerm =
    any (searchTerm &)
    [ Text.all (`elem` Chars.operator)
    , Text.all Char.isAlphaNum
    , (`Text.isPrefixOf` "{}")
    , (== "\\")
    , Lens.has (Lens.reversed . Lens._Cons . Lens.filtered inj)
    ]
    where
        inj (lastChar, revInit) =
            lastChar `elem` suffixes && Text.all Char.isAlphaNum revInit

allowedFragmentSearchTerm :: Text -> Bool
allowedFragmentSearchTerm searchTerm =
    allowedSearchTermCommon ":" searchTerm || isGetField searchTerm
    where
        isGetField t =
            case Text.uncons t of
            Just (c, rest) -> c == '.' && Text.all Char.isAlphaNum rest
            Nothing -> False

-- | Given a hole result sugared expression, determine which part of
-- the search term is a remainder and which belongs inside the hole
-- result expr
getSearchStringRemainder ::
    SearchMenu.ResultsContext -> Expression name i o a -> Text
getSearchStringRemainder ctx holeResult
    | isA _BodyInject = ""
      -- NOTE: This is wrong for operator search terms like ".." which
      -- should NOT have a remainder, but do. We might want to correct
      -- that.  However, this does not cause any bug because search
      -- string remainders are genreally ignored EXCEPT in
      -- apply-operator, which does not occur when the search string
      -- already is an operator.
    | isSuffixed ":" = ":"
    | isSuffixed "." = "."
    | otherwise = ""
    where
        isSuffixed suffix = Text.isSuffixOf suffix (ctx ^. SearchMenu.rSearchTerm)
        fragmentExpr = body . _BodyFragment . fExpr
        isA x = any (`Lens.has` holeResult) [body . x, fragmentExpr . body . x]

injectMVal :: Lens.Traversal' (Expression name i o a) (InjectVal name i o a)
injectMVal = body . _BodyInject . iMVal

verifyInjectSuffix :: Text -> Expression name i o a -> Bool
verifyInjectSuffix searchTerm x =
    case suffix of
    Just ':' | Lens.has (injectMVal . _InjectNullary) x -> False
    Just '.' | Lens.has (injectMVal . _InjectVal) x -> False
    _ -> True
    where
        suffix = searchTerm ^? Lens.reversed . Lens._Cons . _1

-- | Returns the part of the search term that is DEFINITELY part of
-- it. Some of the stripped suffix may be part of the search term,
-- depending on the val.
definitePart :: Text -> Text
definitePart searchTerm
    | Text.any Char.isAlphaNum searchTerm
    && any (`Text.isSuffixOf` searchTerm) [":", "."] = Text.init searchTerm
    | otherwise = searchTerm
