{-# LANGUAGE TupleSections, FlexibleContexts #-}

{- |
Module      : Language.Egison.ParserNonS
Copyright   : Satoshi Egi
Licence     : MIT

This module provide Egison parser.
-}

module Language.Egison.ParserNonS
       (
       -- * Parse a string
         readTopExprs
       , readTopExpr
       , readExprs
       , readExpr
       , parseTopExprs
       , parseTopExpr
       , parseExprs
       , parseExpr
       -- * Parse a file
       , loadLibraryFile
       , loadFile
       ) where

import Prelude hiding (mapM)
import Control.Monad.Identity hiding (mapM)
import Control.Monad.Except hiding (mapM)
import Control.Monad.State hiding (mapM)
import Control.Applicative ((<$>), (<*>), (*>), (<*), pure)

import System.Directory (doesFileExist, getHomeDirectory)

import qualified Data.Sequence as Sq
import Data.Either
import Data.Char (isLower, isUpper, toLower)
import qualified Data.Set as Set
import Data.Traversable (mapM)
import Data.Ratio
import Data.List (intercalate)
import Data.List.Split (split, splitOn, startsWithOneOf)

import Text.Parsec
import Text.Parsec.String
import Text.Parsec.Expr
import qualified Text.Parsec.Token as P

import qualified Data.Text as T
import Text.Regex.TDFA

import Language.Egison.Types
import Language.Egison.Desugar
import Paths_egison (getDataFileName)

readTopExprs :: String -> EgisonM [EgisonTopExpr]
readTopExprs = either throwError (mapM desugarTopExpr) . parseTopExprs

readTopExpr :: String -> EgisonM EgisonTopExpr
readTopExpr = either throwError desugarTopExpr . parseTopExpr

readExprs :: String -> EgisonM [EgisonExpr]
readExprs = liftEgisonM . runDesugarM . either throwError (mapM desugar) . parseExprs

readExpr :: String -> EgisonM EgisonExpr
readExpr = liftEgisonM . runDesugarM . either throwError desugar . parseExpr

parseTopExprs :: String -> Either EgisonError [EgisonTopExpr]
parseTopExprs = doParse $ do
  ret <- whiteSpace >> endBy topExpr whiteSpace
  eof
  return ret

parseTopExpr :: String -> Either EgisonError EgisonTopExpr
parseTopExpr = doParse $ do
  ret <- whiteSpace >> topExpr
  whiteSpace >> eof
  return ret

parseExprs :: String -> Either EgisonError [EgisonExpr]
parseExprs = doParse $ do
  ret <- whiteSpace >> endBy expr whiteSpace
  eof
  return ret

parseExpr :: String -> Either EgisonError EgisonExpr
parseExpr = doParse $ do
  ret <- whiteSpace >> expr
  whiteSpace >> eof
  return ret

-- |Load a libary file
loadLibraryFile :: FilePath -> EgisonM [EgisonTopExpr]
loadLibraryFile file = do
  homeDir <- liftIO $ getHomeDirectory
  doesExist <- liftIO $ doesFileExist $ homeDir ++ "/.egison/" ++ file
  if doesExist
    then loadFile $ homeDir ++ "/.egison/" ++ file
    else liftIO (getDataFileName file) >>= loadFile

-- |Load a file
loadFile :: FilePath -> EgisonM [EgisonTopExpr]
loadFile file = do
  doesExist <- liftIO $ doesFileExist file
  unless doesExist $ throwError $ Default ("file does not exist: " ++ file)
  input <- liftIO $ readUTF8File file
  exprs <- readTopExprs $ shebang input
  concat <$> mapM  recursiveLoad exprs
 where
  recursiveLoad (Load _ file) = loadLibraryFile file
  recursiveLoad (LoadFile _ file) = loadFile file
  recursiveLoad expr = return [expr]
  shebang :: String -> String
  shebang ('#':'!':cs) = ';':'#':'!':cs
  shebang cs = cs

--
-- Parser
--

doParse :: Parser a -> String -> Either EgisonError a
doParse p input = either (throwError . fromParsecError) return $ parse p "egison" input
  where
    fromParsecError :: ParseError -> EgisonError
    fromParsecError = Parser . show

--
-- Expressions
--

topExpr :: Parser EgisonTopExpr
topExpr = try defineExpr
      <|> try (Test <$> expr)
-- topExpr = try (Test <$> expr)
      -- <|> try (parens (redefineExpr
      --              <|> testExpr
      --              <|> executeExpr
      --              <|> loadFileExpr
      --              <|> loadExpr))
      <?> "top-level expression"

defineExpr :: Parser EgisonTopExpr
defineExpr = try (Define <$> identVar <*> (LambdaExpr <$> (parens argNames') <* (inSpaces $ string "=") <* notFollowedBy (string "=") <*> expr))
             <|> try (Define <$> identVar <* (inSpaces $ string "=") <* notFollowedBy (string "=") <*> expr)
             <|> try (do (VarWithIndices name is) <- identVarWithIndices
                         inSpaces $ string "=" >> notFollowedBy (string "=")
                         body <- expr
                         return $ Define (Var name (map f is)) (WithSymbolsExpr (map g is) (TransposeExpr (CollectionExpr (map (ElementExpr . h) is)) body)))
 where
  argNames' :: Parser [Arg]
  argNames' = sepEndBy argName' comma
  argName' :: Parser Arg
  argName' = try (ident >>= return . ScalarArg)
        <|> try (char '*' >> ident >>= return . InvertedScalarArg)
        <|> try (char '%' >> ident >>= return . TensorArg)
  f (Superscript _) = Superscript ()
  f (Subscript _) = Subscript ()
  f (SupSubscript _) = SupSubscript ()
  g (Superscript i) = i
  g (Subscript i) = i
  g (SupSubscript i) = i
  h (Superscript i) = (VarExpr $ stringToVar i)
  h (Subscript i) = (VarExpr $ stringToVar i)
  h (SupSubscript i) = (VarExpr $ stringToVar i)

redefineExpr :: Parser EgisonTopExpr
redefineExpr = (keywordRedefine <|> keywordSet) >> Redefine <$> (char '$' >> identVar) <*> expr

testExpr :: Parser EgisonTopExpr
testExpr = keywordTest >> Test <$> expr

executeExpr :: Parser EgisonTopExpr
executeExpr = keywordExecute >> Execute <$> expr

loadFileExpr :: Parser EgisonTopExpr
loadFileExpr = keywordLoadFile >> LoadFile False <$> stringLiteral

loadExpr :: Parser EgisonTopExpr
loadExpr = keywordLoad >> Load False <$> stringLiteral

exprs :: Parser [EgisonExpr]
exprs = endBy expr whiteSpace

expr :: Parser EgisonExpr
expr = (try applyInfixExpr
        <|> try exprWithSymbol
        <|> try (buildExpressionParser table arg)
        <|> try ifExpr
        <|> try term)
        <?> "expression"
 where
  arg = (char '$' *> notFollowedBy varExpr *> (LambdaArgExpr <$> option "" index))
        <|> term
  index = (:) <$> satisfy (\c -> '1' <= c && c <= '9') <*> many digit
  table = [ [unary "not" AssocRight]
          , [binary "^" "**" AssocLeft]
          , [unary "-" AssocLeft]
          , [binary "*" "*" AssocLeft, binary "/" "/" AssocLeft, binary "." "." AssocLeft]
          , [binary "+" "+" AssocLeft, binary "-" "-" AssocLeft, binary "%" "remainder" AssocLeft]
          , [binary "==" "eq?" AssocLeft, binary "<=" "lte?" AssocLeft, binary "<" "lt?" AssocLeft, binary ">=" "gte?" AssocLeft, binary ">" "gt?" AssocLeft]
          , [binary ":" "cons" AssocLeft, binary ".." "between" AssocLeft]
          , [binary "and" "and" AssocLeft, binary "or" "or" AssocLeft]
          , [binary "++" "join" AssocRight]
          ]
  unary "-" assoc = Prefix (try $ inSpaces (string "-") >> (return $ \x -> (makeApply (VarExpr $ stringToVar "*") [IntegerExpr (-1), x])))
  unary op assoc = Prefix (try $ inSpaces (string op) >> (return $ \x -> makeApply (VarExpr $ stringToVar op) [x]))
  binary op name assoc
    | op == "/" = Infix (try $ (try (inSpaces1 $ string op) <|> ((inSpaces $ string op) >> notFollowedBy (string "m" <|> string "f"))) >> (return $ \x y -> makeApply (VarExpr $ stringToVar name) [x, y])) assoc
    | (op == "." || op == "%") = Infix (try $ (inSpaces1 $ string op) >> (return $ \x y -> makeApply (VarExpr $ stringToVar name) [x, y])) assoc
    | otherwise = Infix (try $ inSpaces (string op) >> (return $ \x y -> makeApply (VarExpr $ stringToVar name) [x, y])) assoc

inSpaces :: Parser a -> Parser ()
inSpaces p = skipMany (space <|> newline) >> p >> skipMany (space <|> newline)

inSpaces1 :: Parser a -> Parser ()
inSpaces1 p = skipMany (space <|> newline) >> p >> skipMany1 (space <|> newline)

exprWithSymbol :: Parser EgisonExpr
exprWithSymbol = (string "d/d" >> applyExpr'' (VarExpr $ stringToVar "d/d"))
                 <|> (string "V.*" >> applyExpr'' (VarExpr $ stringToVar "V.*"))
                 <|> (string "M.*" >> applyExpr'' (VarExpr $ stringToVar "M.*"))
                 <|> (lookAhead (string "let*") >> letStarExpr)

term :: Parser EgisonExpr
term = P.lexeme lexer
        (do term0 <- term'
            option term0 $ try (IndexedExpr False term0 <$ string "..." <*> parseindex
                           <|> IndexedExpr True term0 <$> parseindex))
 where
  parseindex :: Parser [Index EgisonExpr]
  parseindex = many1 $ try (MultiSubscript <$ char '_' <*> term' <* string "..._" <*> term')
                       <|> try (MultiSuperscript <$ char '~' <*> term' <* string "...~" <*> term')
                       <|> try (char '_' >> Subscript <$> term')
                       <|> try (char '~' >> Superscript <$> term')
                       <|> try (string "~_" >> SupSubscript <$> term')
                       <|> try (char '|' >> Userscript <$> term')

term' :: Parser EgisonExpr
term' = (matchExpr
          <|> matchAllExpr
          <|> matcherExpr
          <|> functionWithArgExpr
          <|> userrefsExpr
          <|> algebraicDataMatcherExpr
          <|> try applyExpr
          <|> try partialExpr
          <|> try partialVarExpr
          <|> try freshVarExpr
          <|> try constantExpr
          <|> try lambdaExpr
          <|> try withSymbolsExpr
          <|> try varExpr
          <|> try vectorExpr
          <|> try tupleExpr
          <|> try hashExpr
          <|> try collectionExpr
          <|> inductiveDataExpr
          <|> doExpr
          <|> generateTensorExpr
          <|> tensorExpr
          <|> letExpr
          <|> letRecExpr
          <|> letStarExpr
          <|> patternFunctionExpr
          <|> quoteExpr
          <|> quoteSymbolExpr
          <|> tensorContractExpr
          <|> subrefsExpr
          <|> suprefsExpr
          <|> parens expr
--              <|> wedgeExpr
--              <|> parens (memoizedLambdaExpr
--                          <|> memoizeExpr
--                          <|> procedureExpr
--                          <|> macroExpr
--                          <|> ioExpr
--                          <|> seqExpr
--                          <|> cApplyExpr
--                          <|> symbolicTensorExpr
--                          <|> parExpr
--                          <|> pseqExpr
--                          <|> pmapExpr
--
--                          <|> nextMatchAllExpr
--                          <|> nextMatchExpr
--                          <|> nextMatchAllLambdaExpr
--                          <|> nextMatchLambdaExpr
--                          <|> tensorMapExpr
--                          <|> tensorMap2Expr
--                          <|> transposeExpr
--                          )
             <?> "simple expression")

varExpr :: Parser EgisonExpr
varExpr = VarExpr <$> identVarWithoutIndex

freshVarExpr :: Parser EgisonExpr
freshVarExpr = char '#' >> return FreshVarExpr

inductiveDataExpr :: Parser EgisonExpr
inductiveDataExpr = angles $ InductiveDataExpr <$> upperName <*> sepEndBy expr whiteSpace

tupleExpr :: Parser EgisonExpr
tupleExpr = parens $ TupleExpr <$> sepEndBy expr comma

collectionExpr :: Parser EgisonExpr
collectionExpr = brackets (CollectionExpr <$> sepEndBy innerExpr comma)
                 <|> braces (CollectionExpr <$> sepEndBy innerExpr comma)
 where
  innerExpr :: Parser InnerExpr
  innerExpr = (char '@' >> SubCollectionExpr <$> expr)
               <|> ElementExpr <$> expr

vectorExpr :: Parser EgisonExpr
vectorExpr = between lp rp $ VectorExpr <$> sepEndBy expr comma
  where
    lp = P.lexeme lexer (string "[|")
    rp = string "|]"

hashExpr :: Parser EgisonExpr
hashExpr = between lp rp $ HashExpr <$> sepEndBy pairExpr comma
  where
    lp = P.lexeme lexer (string "{|")
    rp = string "|}"
    pairExpr :: Parser (EgisonExpr, EgisonExpr)
    pairExpr = brackets $ (,) <$> expr <* comma <*> expr

quoteExpr :: Parser EgisonExpr
quoteExpr = char '\'' >> QuoteExpr <$> expr

wedgeExpr :: Parser EgisonExpr
wedgeExpr = char '!' >> WedgeExpr <$> expr

functionWithArgExpr :: Parser EgisonExpr
functionWithArgExpr = keywordFunction >> FunctionExpr <$> (parens $ sepEndBy expr comma)

symbolicTensorExpr :: Parser EgisonExpr
symbolicTensorExpr = keywordSymbolicTensor >> SymbolicTensorExpr <$> (brackets $ sepEndBy expr whiteSpace) <*> expr <*> ident

quoteSymbolExpr :: Parser EgisonExpr
quoteSymbolExpr = char '`' >> QuoteSymbolExpr <$> expr

matchAllExpr :: Parser EgisonExpr
matchAllExpr = keywordMatchAll >> MatchAllExpr <$> expr <* (inSpaces $ string "as") <*> expr <*> matchClause

matchExpr :: Parser EgisonExpr
matchExpr = keywordMatch >> MatchExpr <$> expr <* (inSpaces $ string "as") <*> expr <*> matchClauses

nextMatchAllExpr :: Parser EgisonExpr
nextMatchAllExpr = keywordNextMatchAll >> NextMatchAllExpr <$> expr <*> expr <*> matchClause

nextMatchExpr :: Parser EgisonExpr
nextMatchExpr = keywordNextMatch >> NextMatchExpr <$> expr <*> expr <*> matchClauses

nextMatchAllLambdaExpr :: Parser EgisonExpr
nextMatchAllLambdaExpr = keywordNextMatchAllLambda >> NextMatchAllLambdaExpr <$> expr <*> matchClause

nextMatchLambdaExpr :: Parser EgisonExpr
nextMatchLambdaExpr = keywordNextMatchLambda >> NextMatchLambdaExpr <$> expr <*> matchClauses

matchClauses :: Parser [MatchClause]
matchClauses = many1 matchClause

matchClause :: Parser MatchClause
matchClause = inSpaces (string "|") >> (,) <$> pattern <* (reservedOp "->") <*> expr

matcherExpr :: Parser EgisonExpr
matcherExpr = keywordMatcher >> MatcherExpr <$> ppMatchClauses

ppMatchClauses :: Parser MatcherInfo
ppMatchClauses = braces $ sepEndBy ppMatchClause comma

ppMatchClause :: Parser (PrimitivePatPattern, EgisonExpr, [(PrimitiveDataPattern, EgisonExpr)])
ppMatchClause = brackets $ (,,) <$> ppPattern <*> expr <*> pdMatchClauses

pdMatchClauses :: Parser [(PrimitiveDataPattern, EgisonExpr)]
pdMatchClauses = braces $ sepEndBy pdMatchClause comma

pdMatchClause :: Parser (PrimitiveDataPattern, EgisonExpr)
pdMatchClause = brackets $ (,) <$> pdPattern <*> expr

ppPattern :: Parser PrimitivePatPattern
ppPattern = P.lexeme lexer (ppWildCard
                        <|> ppPatVar
                        <|> ppValuePat
                        <|> ppInductivePat
                        <?> "primitive-pattren-pattern")

ppWildCard :: Parser PrimitivePatPattern
ppWildCard = reservedOp "_" *> pure PPWildCard

ppPatVar :: Parser PrimitivePatPattern
ppPatVar = reservedOp "$" *> pure PPPatVar

ppValuePat :: Parser PrimitivePatPattern
ppValuePat = reservedOp ",$" >> PPValuePat <$> ident

ppInductivePat :: Parser PrimitivePatPattern
ppInductivePat = angles (PPInductivePat <$> lowerName <*> sepEndBy ppPattern whiteSpace)

pdPattern :: Parser PrimitiveDataPattern
pdPattern = P.lexeme lexer $ pdPattern'

pdPattern' :: Parser PrimitiveDataPattern
pdPattern' = reservedOp "_" *> pure PDWildCard
                    <|> (char '$' >> PDPatVar <$> ident)
                    <|> braces ((PDConsPat <$> pdPattern <*> (char '@' *> pdPattern))
                            <|> (PDSnocPat <$> (char '@' *> pdPattern) <*> pdPattern)
                            <|> pure PDEmptyPat)
                    <|> angles (PDInductivePat <$> upperName <*> sepEndBy pdPattern whiteSpace)
                    <|> brackets (PDTuplePat <$> sepEndBy pdPattern whiteSpace)
                    <|> PDConstantPat <$> constantExpr
                    <?> "primitive-data-pattern"

ifExpr :: Parser EgisonExpr
ifExpr = keywordIf >> IfExpr <$> expr <*> expr <* (inSpaces $ string "else") <*> expr

lambdaExpr :: Parser EgisonExpr
lambdaExpr = (LambdaExpr <$> argNames <* reservedOp "->" <*> expr)

memoizedLambdaExpr :: Parser EgisonExpr
memoizedLambdaExpr = keywordMemoizedLambda >> MemoizedLambdaExpr <$> varNames <*> expr

memoizeExpr :: Parser EgisonExpr
memoizeExpr = keywordMemoize >> MemoizeExpr <$> memoizeFrame <*> expr

memoizeFrame :: Parser [(EgisonExpr, EgisonExpr, EgisonExpr)]
memoizeFrame = braces $ sepEndBy memoizeBinding whiteSpace

memoizeBinding :: Parser (EgisonExpr, EgisonExpr, EgisonExpr)
memoizeBinding = brackets $ (,,) <$> expr <*> expr <*> expr

cambdaExpr :: Parser EgisonExpr
cambdaExpr = keywordCambda >> char '$' >> CambdaExpr <$> ident <*> expr

procedureExpr :: Parser EgisonExpr
procedureExpr = keywordProcedure >> ProcedureExpr <$> varNames <*> expr

macroExpr :: Parser EgisonExpr
macroExpr = keywordMacro >> MacroExpr <$> varNames <*> expr

patternFunctionExpr :: Parser EgisonExpr
patternFunctionExpr = keywordPatternFunction >> parens (PatternFunctionExpr <$> (brackets $ sepEndBy ident comma) <* comma <*> pattern)

letRecExpr :: Parser EgisonExpr
letRecExpr =  keywordLetRec >> LetRecExpr <$> bindings <* keywordLetIn <*> expr

letExpr :: Parser EgisonExpr
letExpr = keywordLet >> LetExpr <$> bindings <* keywordLetIn <*> expr

letStarExpr :: Parser EgisonExpr
letStarExpr = keywordLetStar >> LetStarExpr <$> bindings <* keywordLetIn <*> expr

withSymbolsExpr :: Parser EgisonExpr
withSymbolsExpr = keywordWithSymbols >> WithSymbolsExpr <$> (braces $ sepEndBy ident comma) <*> expr

doExpr :: Parser EgisonExpr
doExpr = keywordDo >> DoExpr <$> statements <*> option (ApplyExpr (VarExpr $ stringToVar "return") (TupleExpr [])) expr

statements :: Parser [BindingExpr]
statements = braces $ sepEndBy statement whiteSpace

statement :: Parser BindingExpr
statement = try binding
        <|> try (brackets (([],) <$> expr))
        <|> (([],) <$> expr)

bindings :: Parser [BindingExpr]
bindings = sepEndBy binding comma

binding :: Parser BindingExpr
binding = (,) <$> varNames' <* inSpaces (string "=") <*> expr

varNames :: Parser [String]
varNames = return <$> ident
            <|> parens (sepEndBy ident comma)

varNames' :: Parser [Var]
varNames' = return <$> identVar
            <|> parens (sepEndBy identVar comma)

argNames :: Parser [Arg]
argNames = sepEndBy argName comma

argName :: Parser Arg
argName = try (char '$' >> ident >>= return . ScalarArg)
      <|> try (string "*$" >> ident >>= return . InvertedScalarArg)
      <|> try (char '%' >> ident >>= return . TensorArg)

ioExpr :: Parser EgisonExpr
ioExpr = keywordIo >> IoExpr <$> expr

seqExpr :: Parser EgisonExpr
seqExpr = keywordSeq >> SeqExpr <$> expr <*> expr

cApplyExpr :: Parser EgisonExpr
cApplyExpr = (keywordCApply >> CApplyExpr <$> expr <*> expr)

applyExpr :: Parser EgisonExpr
applyExpr = (keywordApply >> ApplyExpr <$> expr <*> expr)
            <|> try applyExpr'

applyExpr' :: Parser EgisonExpr
applyExpr' = do
  func <- try varExpr <|> try partialExpr <|> try partialVarExpr <|> (parens expr)
  applyExpr'' func

applyExpr'' :: EgisonExpr -> Parser EgisonExpr
applyExpr'' func = do
  argslist <- many1 $ parens args
  return $ foldl (\acc xs -> makeApply acc xs) func argslist
 where
  args = sepEndBy arg $ comma
  arg = try expr
        <|> char '$' *> (LambdaArgExpr <$> option "" index)
  index = (:) <$> satisfy (\c -> '1' <= c && c <= '9') <*> many digit

applyInfixExpr :: Parser EgisonExpr
applyInfixExpr = do
  arg1 <- arg
  spaces
  func <- (char '`' *> varExpr <* char '`')
  spaces
  arg2 <- arg
  return $ makeApply func [arg1, arg2]
 where
  arg = try term
        <|> char '$' *> (LambdaArgExpr <$> option "" index)
  index = (:) <$> satisfy (\c -> '1' <= c && c <= '9') <*> many digit

makeApply :: EgisonExpr -> [EgisonExpr] -> EgisonExpr
makeApply func xs = do
  let args = map (\x -> case x of
                          LambdaArgExpr s -> Left s
                          _ -> Right x) xs
  let vars = lefts args
  case vars of
    [] -> ApplyExpr func . TupleExpr $ rights args
    _ | all null vars ->
        let args' = rights args
            args'' = map f (zip args (annonVars 1 (length args)))
            args''' = map (VarExpr . stringToVar . (either id id)) args''
        in ApplyExpr (LambdaExpr (map ScalarArg (rights args'')) (LambdaExpr (map ScalarArg (lefts args'')) $ ApplyExpr func $ TupleExpr args''')) $ TupleExpr args'
      | all (not . null) vars ->
        let n = Set.size $ Set.fromList vars
            args' = rights args
            args'' = map g (zip args (annonVars (n + 1) (length args)))
            args''' = map (VarExpr . stringToVar . (either id id)) args''
        in ApplyExpr (LambdaExpr (map ScalarArg (rights args'')) (LambdaExpr (map ScalarArg (annonVars 1 n)) $ ApplyExpr func $ TupleExpr args''')) $ TupleExpr args'
 where
  annonVars m n = take n $ map ((':':) . show) [m..]
  f ((Left _), var) = Left var
  f ((Right _), var) = Right var
  g ((Left arg), _) = Left (':':arg)
  g ((Right _), var) = Right var

partialExpr :: Parser EgisonExpr
partialExpr = PartialExpr <$> read <$> index <*> (char '#' >> (try (parens expr) <|> expr))
 where
  index = (:) <$> satisfy (\c -> '1' <= c && c <= '9') <*> many digit

partialVarExpr :: Parser EgisonExpr
partialVarExpr = char '%' >> PartialVarExpr <$> integerLiteral

algebraicDataMatcherExpr :: Parser EgisonExpr
algebraicDataMatcherExpr = keywordAlgebraicDataMatcher
                                >> AlgebraicDataMatcherExpr <$> parens (sepEndBy1 inductivePat' comma)
  where
    inductivePat' :: Parser (String, [EgisonExpr])
    inductivePat' = angles $ (,) <$> lowerName <*> sepEndBy expr whiteSpace

generateTensorExpr :: Parser EgisonExpr
generateTensorExpr = keywordGenerateTensor >> parens (GenerateTensorExpr <$> expr <* comma <*> expr)

tensorExpr :: Parser EgisonExpr
tensorExpr = keywordTensor >> parens (TensorExpr <$> expr <* comma <*> expr <*> option (CollectionExpr []) (comma *> expr) <*> option (CollectionExpr []) (comma *> expr))

tensorContractExpr :: Parser EgisonExpr
tensorContractExpr = keywordTensorContract >> parens (TensorContractExpr <$> expr <* comma <*> expr)

tensorMapExpr :: Parser EgisonExpr
tensorMapExpr = keywordTensorMap >> TensorMapExpr <$> expr <*> expr

tensorMap2Expr :: Parser EgisonExpr
tensorMap2Expr = keywordTensorMap2 >> TensorMap2Expr <$> expr <*> expr <*> expr

transposeExpr :: Parser EgisonExpr
transposeExpr = keywordTranspose >> TransposeExpr <$> expr <*> expr

parExpr :: Parser EgisonExpr
parExpr = keywordPar >> ParExpr <$> expr <*> expr

pseqExpr :: Parser EgisonExpr
pseqExpr = keywordPseq >> PseqExpr <$> expr <*> expr

pmapExpr :: Parser EgisonExpr
pmapExpr = keywordPmap >> PmapExpr <$> expr <*> expr

subrefsExpr :: Parser EgisonExpr
subrefsExpr = (keywordSubrefs >> parens (SubrefsExpr False <$> expr <* comma <*> expr))
               <|> (keywordSubrefsNew >> parens (SubrefsExpr True <$> expr <* comma <*> expr))

suprefsExpr :: Parser EgisonExpr
suprefsExpr = (keywordSuprefs >> SuprefsExpr False <$> expr <*> expr)
               <|> (keywordSuprefsNew >> SuprefsExpr True <$> expr <*> expr)

userrefsExpr :: Parser EgisonExpr
userrefsExpr = (do keywordUserrefs
                   xs <- parens $ sepEndBy expr comma
                   case xs of
                     [x, y] -> return $ UserrefsExpr False x y
                     _ -> unexpected "number of arguments (expected 2)")
                <|> (do keywordUserrefsNew
                        xs <- parens $ sepEndBy expr comma
                        case xs of
                          [x, y] -> return $ UserrefsExpr True x y
                          _ -> unexpected "number of arguments (expected 2)")

-- Patterns

pattern :: Parser EgisonPattern
pattern = P.lexeme lexer
            (try (buildExpressionParser table pattern')
             <|> try pattern'
             <?> "expression")

 where
  table = [ [unary "!" AssocRight, unary "not" AssocRight]
          , [binary "*" "mult" AssocLeft, binary "/" "div" AssocLeft]
          , [binary "+" "plus" AssocLeft]
          , [binary "<:>" "cons" AssocRight]
          , [binary' "and" AndPat AssocLeft, binary' "or*" OrderedOrPat' AssocLeft, binary' "or" OrPat AssocLeft]
          , [binary "<++>" "join" AssocRight]
          ]
  unary op assoc = Prefix (try $ inSpaces (string op) >> (return $ \x -> NotPat x))
  binary "+" name assoc = Infix (try $ inSpaces (string "+") >> notFollowedBy (string "+") >> (return $ \x y -> InductivePat name [x, y])) assoc
  binary op name assoc = Infix (try $ inSpaces (string op) >> (return $ \x y -> InductivePat name [x, y])) assoc
  binary' op epr assoc = Infix (try $ inSpaces (string op) >> (return $ \x y -> epr [x, y])) assoc

pattern' :: Parser EgisonPattern
pattern' = wildCard
           <|> contPat
           <|> try indexedPat
           <|> patVar
           <|> try dfsPat
           <|> try bfsPat
           <|> try loopPat
           <|> try pApplyPat
           <|> try dApplyPat
           <|> try varPat
           <|> valuePat
           <|> predPat
           <|> try tuplePat
           <|> inductivePat
           <|> letPat
           <|> parens pattern

pattern'' :: Parser EgisonPattern
pattern'' = wildCard
            <|> patVar
            <|> valuePat

wildCard :: Parser EgisonPattern
wildCard = reservedOp "_" >> pure WildCard

indexedPat :: Parser EgisonPattern
indexedPat = IndexedPat <$> (patVar <|> varPat) <*> many1 (try $ char '_' >> term')

patVar :: Parser EgisonPattern
patVar = char '$' >> PatVar <$> identVarWithoutIndex

varPat :: Parser EgisonPattern
varPat = char '\'' >> VarPat <$> ident

valuePat :: Parser EgisonPattern
valuePat = ValuePat <$> expr

predPat :: Parser EgisonPattern
predPat = char '?' >> PredPat <$> expr

letPat :: Parser EgisonPattern
letPat = keywordLet >> LetPat <$> bindings <* keywordLetIn <*> pattern

tuplePat :: Parser EgisonPattern
tuplePat = TuplePat <$> parens ((:) <$> pattern <* comma <*> sepEndBy1 pattern comma)

inductivePat :: Parser EgisonPattern
inductivePat = angles $ InductivePat <$> lowerName <*> sepEndBy pattern whiteSpace

contPat :: Parser EgisonPattern
contPat = keywordCont >> pure ContPat

pApplyPat :: Parser EgisonPattern
pApplyPat = PApplyPat <$> expr <*> brackets (sepEndBy pattern comma)

dApplyPat :: Parser EgisonPattern
dApplyPat = DApplyPat <$> pattern'' <*> parens (sepEndBy pattern comma)

loopPat :: Parser EgisonPattern
loopPat = keywordLoop >> parens (char '$' >> LoopPat <$> identVarWithoutIndex <*> (comma >> loopRange) <*> (comma >> pattern) <*> (comma >> option (NotPat WildCard) pattern))

loopRange :: Parser LoopRange
loopRange = brackets (try (do s <- expr
                              comma
                              e <- expr
                              comma
                              ep <- option WildCard pattern
                              return (LoopRange s e ep))
                 <|> (do s <- expr
                         comma
                         ep <- option WildCard pattern
                         return (LoopRange s (ApplyExpr (VarExpr $ stringToVar "from") (ApplyExpr (VarExpr $ stringToVar "-'") (TupleExpr [s, (IntegerExpr 1)]))) ep)))

dfsPat :: Parser EgisonPattern
dfsPat = keywordDFS >> DFSPat' <$> parens pattern

bfsPat :: Parser EgisonPattern
bfsPat = keywordBFS >> BFSPat <$> parens pattern

-- Constants

constantExpr :: Parser EgisonExpr
constantExpr = stringExpr
                 <|> boolExpr
                 <|> try charExpr
                 <|> try floatExpr
                 <|> try integerExpr
                 <|> (keywordSomething *> pure SomethingExpr)
                 <|> (keywordUndefined *> pure UndefinedExpr)
                 <?> "constant"

charExpr :: Parser EgisonExpr
charExpr = CharExpr <$> charLiteral

stringExpr :: Parser EgisonExpr
stringExpr = StringExpr . T.pack <$> stringLiteral

boolExpr :: Parser EgisonExpr
boolExpr = BoolExpr <$> boolLiteral

floatExpr :: Parser EgisonExpr
floatExpr = do
  (x,y) <- try (do x <- floatLiteral'
                   y <- sign' <*> positiveFloatLiteral
                   char 'i'
                   return (x,y))
            <|> try (do y <- floatLiteral'
                        char 'i'
                        return (0,y))
            <|> try (do x <- floatLiteral'
                        return (x,0))
  return $ FloatExpr x y

integerExpr :: Parser EgisonExpr
integerExpr = do
  n <- integerLiteral'
  return $ IntegerExpr n

integerLiteral' :: Parser Integer
integerLiteral' = sign <*> positiveIntegerLiteral

positiveIntegerLiteral :: Parser Integer
positiveIntegerLiteral = read <$> many1 digit

positiveFloatLiteral :: Parser Double
positiveFloatLiteral = do
  n <- positiveIntegerLiteral
  char '.'
  mStr <- many1 digit
  let m = read mStr
  let l = m % (10 ^ (fromIntegral (length mStr)))
  return (fromRational ((fromIntegral n) + l) :: Double)

floatLiteral' :: Parser Double
floatLiteral' = sign <*> positiveFloatLiteral

--
-- Tokens
--

egisonDef :: P.GenLanguageDef String () Identity
egisonDef =
  P.LanguageDef { P.commentStart       = "#|"
                , P.commentEnd         = "|#"
                , P.commentLine        = ";"
                , P.identStart         = letter <|> symbol1
                , P.identLetter        = letter <|> digit <|> symbol0 <|> symbol2
                , P.opStart            = symbol1
                , P.opLetter           = symbol0 <|> symbol1
                , P.reservedNames      = reservedKeywords
                , P.reservedOpNames    = reservedOperators
                , P.nestedComments     = True
                , P.caseSensitive      = True }

symbol0 = oneOf "/."
symbol1' = oneOf "∂∇"
symbol1 = symbol1' <|> oneOf "+-"
symbol2 = symbol1' <|> oneOf "'!?"

lexer :: P.GenTokenParser String () Identity
lexer = P.makeTokenParser egisonDef

reservedKeywords :: [String]
reservedKeywords =
  [ "define"
  , "redefine"
  , "set!"
  , "test"
  , "execute"
  , "loadFile"
  , "load"
  , "if"
  , "seq"
  , "apply"
  , "capply"
  , "lambda"
  , "memoizedLambda"
  , "memoize"
  , "cambda"
  , "procedure"
  , "macro"
  , "patternFunction"
  , "letrec"
  , "let"
  , "let*"
  , "withSymbols"
  , "loop"
  , "matchAll"
  , "match"
  , "matchAllLambda"
  , "matchLambda"
  , "matcher"
  , "do"
  , "io"
  , "algebraicDataMatcher"
  , "generateTensor"
  , "tensor"
  , "contract"
  , "tensorMap"
  , "tensorMap2"
  , "transpose"
  , "par"
  , "pseq"
  , "pmap"
  , "subrefs"
  , "subrefs!"
  , "suprefs"
  , "suprefs!"
  , "userRefs"
  , "userRefs!"
  , "function"
  , "symbolicTensor"
  , "something"
  , "undefined"]

reservedOperators :: [String]
reservedOperators =
  [ "$"
  , ",$"
  , "_"
  , "^"
  , "&"
  , "|*"
  , "("
  , ")"
  , "->"
  , "`"
--  , "'"
--  , "~"
--  , "!"
--  , ","
--  , "@"
  , "..."]

reserved :: String -> Parser ()
reserved = P.reserved lexer

reservedOp :: String -> Parser ()
reservedOp = P.reservedOp lexer

keywordDefine               = reserved "define"
keywordRedefine             = reserved "redefine"
keywordSet                  = reserved "set!"
keywordTest                 = reserved "test"
keywordExecute              = reserved "execute"
keywordLoadFile             = reserved "loadFile"
keywordLoad                 = reserved "load"
keywordIf                   = reserved "if"
keywordThen                 = reserved "then"
keywordElse                 = reserved "else"
keywordSeq                  = reserved "seq"
keywordApply                = reserved "apply"
keywordCApply               = reserved "capply"
keywordLambda               = reserved "lambda"
keywordMemoizedLambda       = reserved "memoizedLambda"
keywordMemoize              = reserved "memoize"
keywordCambda               = reserved "cambda"
keywordProcedure            = reserved "procedure"
keywordMacro                = reserved "macro"
keywordPatternFunction      = reserved "patternFunction"
keywordLetRec               = reserved "letrec"
keywordLet                  = reserved "let"
keywordLetStar              = reserved "let*"
keywordLetIn                = reserved "in"
keywordWithSymbols          = reserved "withSymbols"
keywordLoop                 = reserved "loop"
keywordCont                 = reserved "..."
keywordMatchAll             = reserved "matchAll"
keywordMatchAllLambda       = reserved "matchAllLambda"
keywordMatch                = reserved "match"
keywordMatchLambda          = reserved "matchLambda"
keywordNextMatchAll         = reserved "nextMatchAll"
keywordNextMatchAllLambda   = reserved "nextMatchAllLambda"
keywordNextMatch            = reserved "nextMatch"
keywordNextMatchLambda      = reserved "nextMatchLambda"
keywordMatcher              = reserved "matcher"
keywordDo                   = reserved "do"
keywordIo                   = reserved "io"
keywordSomething            = reserved "something"
keywordUndefined            = reserved "undefined"
keywordAlgebraicDataMatcher = reserved "algebraicDataMatcher"
keywordGenerateTensor       = reserved "generateTensor"
keywordTensor               = reserved "tensor"
keywordTensorContract       = reserved "contract"
keywordTensorMap            = reserved "tensorMap"
keywordTensorMap2           = reserved "tensorMap2"
keywordTranspose            = reserved "transpose"
keywordPar                  = reserved "par"
keywordPseq                 = reserved "pseq"
keywordPmap                 = reserved "pmap"
keywordSubrefs              = reserved "subrefs"
keywordSubrefsNew           = reserved "subrefs!"
keywordSuprefs              = reserved "suprefs"
keywordSuprefsNew           = reserved "suprefs!"
keywordUserrefs             = reserved "userRefs"
keywordUserrefsNew          = reserved "userRefs!"
keywordFunction             = reserved "function"
keywordSymbolicTensor       = reserved "symbolicTensor"
keywordDFS                  = reserved "dfs"
keywordBFS                  = reserved "bfs"

sign :: Num a => Parser (a -> a)
sign = (char '-' >> return negate)
   <|> (char '+' >> return id)
   <|> return id

sign' :: Num a => Parser (a -> a)
sign' = (char '-' >> return negate)
    <|> (char '+' >> return id)

naturalLiteral :: Parser Integer
naturalLiteral = P.natural lexer

integerLiteral :: Parser Integer
integerLiteral = sign <*> P.natural lexer

floatLiteral :: Parser Double
floatLiteral = sign <*> P.float lexer

stringLiteral :: Parser String
stringLiteral = P.stringLiteral lexer

--charLiteral :: Parser Char
--charLiteral = P.charLiteral lexer
charLiteral :: Parser Char
charLiteral = string "c#" >> anyChar

boolLiteral :: Parser Bool
boolLiteral = char '#' >> (char 't' *> pure True <|> char 'f' *> pure False)

whiteSpace :: Parser ()
whiteSpace = P.whiteSpace lexer

parens :: Parser a -> Parser a
parens = P.parens lexer

brackets :: Parser a -> Parser a
brackets = P.brackets lexer

braces :: Parser a -> Parser a
braces = P.braces lexer

angles :: Parser a -> Parser a
angles = P.angles lexer

colon :: Parser String
colon = P.colon lexer

comma :: Parser String
comma = P.comma lexer

dot :: Parser String
dot = P.dot lexer

ident :: Parser String
ident = do
  idt <- P.identifier lexer
  let (f, s) = splitLast idt '.'
  case s of
    [] -> return f
    x:xs | isLower x -> return $ f ++ (map toLower $ intercalate "-" $ split (startsWithOneOf ['A'..'Z']) s)
         | otherwise -> return $ f ++ [x] ++ (map toLower $ intercalate "-" $ split (startsWithOneOf ['A'..'Z']) xs)
 where
  splitLast list elem = let (f, s) = span (/= elem) $ reverse list
                          in (reverse s, reverse f)

identVar :: Parser Var
identVar = P.lexeme lexer (do
  name <- ident
  is <- many indexType
  return $ Var (splitOn "." name) is)

identVarWithoutIndex :: Parser Var
identVarWithoutIndex = do
  x <- ident
  return $ stringToVar x

identVarWithIndices :: Parser VarWithIndices
identVarWithIndices = P.lexeme lexer (do
  name <- ident
  is <- many indexForVar
  return $ VarWithIndices (splitOn "." name) is)

indexForVar :: Parser (Index String)
indexForVar = try (char '~' >> Superscript <$> ident)
        <|> try (char '_' >> Subscript <$> ident)

indexType :: Parser (Index ())
indexType = try (char '~' >> return (Superscript ()))
        <|> try (char '_' >> return (Subscript ()))

upperName :: Parser String
upperName = P.lexeme lexer $ upperName'

upperName' :: Parser String
upperName' = (:) <$> upper <*> option "" ident
 where
  upper :: Parser Char
  upper = satisfy isUpper

lowerName :: Parser String
lowerName = P.lexeme lexer $ lowerName'

lowerName' :: Parser String
lowerName' = (:) <$> lower <*> option "" ident
 where
  lower :: Parser Char
  lower = satisfy isLower
