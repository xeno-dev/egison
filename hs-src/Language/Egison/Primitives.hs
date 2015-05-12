{-# Language FlexibleContexts #-}

{- |
Module      : Language.Egison.Primitives
Copyright   : Satoshi Egi
Licence     : MIT

This module provides primitive functions in Egison.
-}

module Language.Egison.Primitives (primitiveEnv, primitiveEnvNoIO) where

import Control.Arrow
import Control.Monad.Error
import Control.Monad.Trans.Maybe

import Data.IORef
import Data.Ratio
import Data.Foldable (toList)
import Text.Regex.TDFA

import System.IO
import System.Random
import System.Process

import qualified Data.Sequence as Sq

import Data.Char (ord, chr)
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.IO as T

 {--  -- for 'egison-sqlite'
import qualified Database.SQLite3 as SQLite
 --}  -- for 'egison-sqlite'

import Language.Egison.Types
import Language.Egison.Parser
import Language.Egison.Core

primitiveEnv :: IO Env
primitiveEnv = do
  let ops = map (second PrimitiveFunc) (primitives ++ ioPrimitives)
  bindings <- forM (constants ++ ops) $ \(name, op) -> do
    ref <- newIORef . WHNF $ Value op
    return (name, ref)
  return $ extendEnv nullEnv bindings

primitiveEnvNoIO :: IO Env
primitiveEnvNoIO = do
  let ops = map (second PrimitiveFunc) primitives
  bindings <- forM (constants ++ ops) $ \(name, op) -> do
    ref <- newIORef . WHNF $ Value op
    return (name, ref)
  return $ extendEnv nullEnv bindings

{-# INLINE noArg #-}
noArg :: EgisonM EgisonValue -> PrimitiveFunc
noArg f = \args -> do
  args' <- tupleToList args
  case args' of 
    [] -> f >>= return . Value
    _ -> throwError $ ArgumentsNumPrimitive 0 $ length args'

{-# INLINE oneArg #-}
oneArg :: (EgisonValue -> EgisonM EgisonValue) -> PrimitiveFunc
oneArg f = \args -> do
  args' <- evalWHNF args
  f args' >>= return . Value

{-# INLINE twoArgs #-}
twoArgs :: (EgisonValue -> EgisonValue -> EgisonM EgisonValue) -> PrimitiveFunc
twoArgs f = \args -> do
  args' <- tupleToList args
  case args' of 
    [val, val'] -> f val val' >>= return . Value
    _ -> throwError $ ArgumentsNumPrimitive 2 $ length args'

{-# INLINE threeArgs #-}
threeArgs :: (EgisonValue -> EgisonValue -> EgisonValue -> EgisonM EgisonValue) -> PrimitiveFunc
threeArgs f = \args -> do
  args' <- tupleToList args
  case args' of 
    [val, val', val''] -> f val val' val'' >>= return . Value
    _ -> throwError $ ArgumentsNumPrimitive 3 $ length args'

tupleToList :: WHNFData -> EgisonM [EgisonValue]
tupleToList whnf = do
  val <- evalWHNF whnf
  return $ tupleToList' val
 where
  tupleToList' (Tuple vals) = vals
  tupleToList' val = [val]

--
-- Constants
--

constants :: [(String, EgisonValue)]
constants = [ ("pi", Float 3.141592653589793) ]

--
-- Primitives
--

primitives :: [(String, PrimitiveFunc)]
primitives = [ ("+", plus)
             , ("-", minus)
             , ("*", multiply)
             , ("/", divide)
             , ("numerator", numerator')
             , ("denominator", denominator')
               
             , ("modulo",    integerBinaryOp mod)
             , ("quotient",   integerBinaryOp quot)
             , ("remainder", integerBinaryOp rem)
             , ("neg", rationalUnaryOp negate)
             , ("abs", rationalUnaryOp abs)
               
             , ("eq?",  eq)
             , ("lt?",  lt)
             , ("lte?", lte)
             , ("gt?",  gt)
             , ("gte?", gte)
               
             , ("round",    floatToIntegerOp round)
             , ("floor",    floatToIntegerOp floor)
             , ("ceiling",  floatToIntegerOp ceiling)
             , ("truncate", floatToIntegerOp truncate)
               
             , ("sqrt", floatUnaryOp sqrt)
             , ("exp", floatUnaryOp exp)
             , ("log", floatUnaryOp log)
             , ("sin", floatUnaryOp sin)
             , ("cos", floatUnaryOp cos)
             , ("tan", floatUnaryOp tan)
             , ("asin", floatUnaryOp asin)
             , ("acos", floatUnaryOp acos)
             , ("atan", floatUnaryOp atan)
             , ("sinh", floatUnaryOp sinh)
             , ("cosh", floatUnaryOp cosh)
             , ("tanh", floatUnaryOp tanh)
             , ("asinh", floatUnaryOp asinh)
             , ("acosh", floatUnaryOp acosh)
             , ("atanh", floatUnaryOp atanh)
               
             , ("itof", integerToFloat)
             , ("rtof", rationalToFloat)
             , ("ctoi", charToInteger)
             , ("itoc", integerToChar)

             , ("pack", pack)
             , ("unpack", unpack)
             , ("uncons-string", unconsString)
             , ("length-string", lengthString)
             , ("append-string", appendString)
             , ("split-string", splitString)
             , ("regex", regexString)
             , ("regex-cg", regexStringCaptureGroup)

             , ("read-process", readProcess')
               
             , ("read", read')
             , ("read-tsv", readTSV)
             , ("show", show')
             , ("show-tsv", showTSV')

             , ("empty?", isEmpty')
             , ("uncons", uncons')
             , ("unsnoc", unsnoc')

             , ("bool?", isBool)
             , ("integer?", isInteger)
             , ("rational?", isRational)
             , ("float?", isFloat)
             , ("char?", isChar)
             , ("string?", isString)
             , ("collection?", isCollection)
             , ("array?", isArray)
             , ("hash?", isHash)

             , ("assert", assert)
             , ("assert-equal", assertEqual)
             ]

rationalUnaryOp :: (Rational -> Rational) -> PrimitiveFunc
rationalUnaryOp op = oneArg $ \val -> do
  r <- fromEgison val
  return $ Rational $ op r
  
rationalBinaryOp :: (Rational -> Rational -> Rational) -> PrimitiveFunc
rationalBinaryOp op = twoArgs $ \val val' -> do
  r <- fromEgison val
  r' <- fromEgison val'
  return $ Rational $ op r r'

rationalBinaryPred :: (Rational -> Rational -> Bool) -> PrimitiveFunc
rationalBinaryPred pred = twoArgs $ \val val' -> do
  r <- fromEgison val
  r' <- fromEgison val'
  return $ Bool $ pred r r'

integerBinaryOp :: (Integer -> Integer -> Integer) -> PrimitiveFunc
integerBinaryOp op = twoArgs $ \val val' -> do
  r <- fromEgison val
  r' <- fromEgison val'
  return $ Rational $ (op (numerator r) (numerator r') % 1)

integerBinaryPred :: (Integer -> Integer -> Bool) -> PrimitiveFunc
integerBinaryPred pred = twoArgs $ \val val' -> do
  r <- fromEgison val
  r' <- fromEgison val'
  return $ Bool $ pred (numerator r) (numerator r')

floatUnaryOp :: (Double -> Double) -> PrimitiveFunc
floatUnaryOp op = oneArg $ \val -> do
  case val of
    (Float f) -> return $ Float $ op f
    (Rational r) -> return $ Float $ op (fromRational r)

floatBinaryOp :: (Double -> Double -> Double) -> PrimitiveFunc
floatBinaryOp op = twoArgs $ \val val' -> do
  f <- fromEgison val
  f' <- fromEgison val'
  return $ Float $ op f f'

floatBinaryPred :: (Double -> Double -> Bool) -> PrimitiveFunc
floatBinaryPred pred = twoArgs $ \val val' -> do
  f <- fromEgison val
  f' <- fromEgison val'
  return $ Bool $ pred f f'

--
-- Arith
--
plus :: PrimitiveFunc
plus = twoArgs $ \val val' -> numberBinaryOp' val val'
 where
  numberBinaryOp' (Rational r) (Rational r') = return $ Rational (r + r')
  numberBinaryOp' (Rational r) (Float f)     = numberBinaryOp' (Float (fromRational r)) (Float f)
  numberBinaryOp' (Float f)    (Rational r)  = numberBinaryOp' (Float f) (Float (fromRational r))
  numberBinaryOp' (Float f)    (Float f')    = return $ Float (f + f')
  numberBinaryOp' (Rational _) val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryOp' (Float _)    val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryOp' val          _             = throwError $ TypeMismatch "number" (Value val)

minus :: PrimitiveFunc
minus = twoArgs $ \val val' -> numberBinaryOp' val val'
 where
  numberBinaryOp' (Rational r) (Rational r') = return $ Rational (r - r')
  numberBinaryOp' (Rational r) (Float f)     = numberBinaryOp' (Float (fromRational r)) (Float f)
  numberBinaryOp' (Float f)    (Rational r)  = numberBinaryOp' (Float f) (Float (fromRational r))
  numberBinaryOp' (Float f)    (Float f')    = return $ Float (f - f')
  numberBinaryOp' (Rational _) val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryOp' (Float _)    val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryOp' val          _             = throwError $ TypeMismatch "number" (Value val)

multiply :: PrimitiveFunc
multiply = twoArgs $ \val val' -> numberBinaryOp' val val'
 where
  numberBinaryOp' (Rational r) (Rational r') = return $ Rational (r * r')
  numberBinaryOp' (Rational r) (Float f)     = numberBinaryOp' (Float (fromRational r)) (Float f)
  numberBinaryOp' (Float f)    (Rational r)  = numberBinaryOp' (Float f) (Float (fromRational r))
  numberBinaryOp' (Float f)    (Float f')    = return $ Float (f * f')
  numberBinaryOp' (Rational _) val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryOp' (Float _)    val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryOp' val          _             = throwError $ TypeMismatch "number" (Value val)

divide :: PrimitiveFunc
divide = twoArgs $ \val val' -> numberBinaryOp' val val'
 where
  numberBinaryOp' (Rational r) (Rational r') =
    let m = numerator r' in
    let n = denominator r' in
    let y = (r * (n % m)) in
      return $ Rational y
  numberBinaryOp' (Rational r) (Float f)    = numberBinaryOp' (Float (fromRational r)) (Float f)
  numberBinaryOp' (Float f)    (Rational r) = numberBinaryOp' (Float f) (Float (fromRational r))
  numberBinaryOp' (Float f)    (Float f')   = return $ Float $ (/) f f'
  numberBinaryOp' (Rational _) val          = throwError $ TypeMismatch "number" (Value val)
  numberBinaryOp' (Float _)    val          = throwError $ TypeMismatch "number" (Value val)
  numberBinaryOp' val          _            = throwError $ TypeMismatch "number" (Value val)

numerator' :: PrimitiveFunc
numerator' =  oneArg $ numerator''
 where
  numerator'' (Rational rat) = do
    return $ Rational $ (numerator rat) % 1
  numerator'' val = throwError $ TypeMismatch "rational" (Value val)

denominator' :: PrimitiveFunc
denominator' =  oneArg $ denominator''
 where
  denominator'' (Rational rat) = do
    return $ Rational $ (denominator rat) % 1
  denominator'' val = throwError $ TypeMismatch "rational" (Value val)

--
-- Pred
--
eq :: PrimitiveFunc
eq = twoArgs $ \val val' ->
  return $ Bool $ val == val'

lt :: PrimitiveFunc
lt = twoArgs $ \val val' -> numberBinaryPred' val val'
 where
  numberBinaryPred' (Rational r) (Rational r') = return $ Bool $ (<) r r'
  numberBinaryPred' (Rational r) (Float f)     = numberBinaryPred' (Float (fromRational r)) (Float f)
  numberBinaryPred' (Float f)    (Rational r)  = numberBinaryPred' (Float f) (Float (fromRational r))
  numberBinaryPred' (Float f)    (Float f')    = return $ Bool $ (<) f f'
  numberBinaryPred' (Rational _) val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryPred' (Float _)    val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryPred' val          _             = throwError $ TypeMismatch "number" (Value val)
  
lte :: PrimitiveFunc
lte = twoArgs $ \val val' -> numberBinaryPred' val val'
 where
  numberBinaryPred' (Rational r) (Rational r') = return $ Bool $ (<=) r r'
  numberBinaryPred' (Rational r) (Float f)     = numberBinaryPred' (Float (fromRational r)) (Float f)
  numberBinaryPred' (Float f)    (Rational r)  = numberBinaryPred' (Float f) (Float (fromRational r))
  numberBinaryPred' (Float f)    (Float f')    = return $ Bool $ (<=) f f'
  numberBinaryPred' (Rational _) val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryPred' (Float _)    val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryPred' val          _             = throwError $ TypeMismatch "number" (Value val)
  
gt :: PrimitiveFunc
gt = twoArgs $ \val val' -> numberBinaryPred' val val'
 where
  numberBinaryPred' (Rational r) (Rational r') = return $ Bool $ (>) r r'
  numberBinaryPred' (Rational r) (Float f)     = numberBinaryPred' (Float (fromRational r)) (Float f)
  numberBinaryPred' (Float f)    (Rational r)  = numberBinaryPred' (Float f) (Float (fromRational r))
  numberBinaryPred' (Float f)    (Float f')    = return $ Bool $ (>) f f'
  numberBinaryPred' (Rational _) val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryPred' (Float _)    val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryPred' val          _             = throwError $ TypeMismatch "number" (Value val)
  
gte :: PrimitiveFunc
gte = twoArgs $ \val val' -> numberBinaryPred' val val'
 where
  numberBinaryPred' (Rational r) (Rational r') = return $ Bool $ (>=) r r'
  numberBinaryPred' (Rational r) (Float f)     = numberBinaryPred' (Float (fromRational r)) (Float f)
  numberBinaryPred' (Float f)    (Rational r)  = numberBinaryPred' (Float f) (Float (fromRational r))
  numberBinaryPred' (Float f)    (Float f')    = return $ Bool $ (>=) f f'
  numberBinaryPred' (Rational _) val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryPred' (Float _)    val           = throwError $ TypeMismatch "number" (Value val)
  numberBinaryPred' val          _             = throwError $ TypeMismatch "number" (Value val)
  
--
-- Transform
--
integerToFloat :: PrimitiveFunc
integerToFloat = rationalToFloat

rationalToFloat :: PrimitiveFunc
rationalToFloat = oneArg $ \val -> do
  case val of
    Rational r -> return $ Float $ fromRational r
    _ -> throwError $ TypeMismatch "integer of rational number" (Value val)

charToInteger :: PrimitiveFunc
charToInteger = oneArg $ \val -> do
  case val of
    Char c -> return $ Rational $ (fromIntegral $ ord c) % 1
    _ -> throwError $ TypeMismatch "character" (Value val)

integerToChar :: PrimitiveFunc
integerToChar = oneArg $ \val -> do
  case val of
    Rational r -> return $ Char $ chr $ fromIntegral (numerator r)
    _ -> throwError $ TypeMismatch "character" (Value val)

floatToIntegerOp :: (Double -> Integer) -> PrimitiveFunc
floatToIntegerOp op = oneArg $ \val -> do
  f <- fromEgison val
  return $ Rational $ (op f) % 1

--
-- String
--
pack :: PrimitiveFunc
pack = oneArg $ \val -> do
  str <- packStringValue val
  return $ String str

unpack :: PrimitiveFunc
unpack = oneArg $ \val -> do
  case val of
    String str -> return $ toEgison (T.unpack str)
    _ -> throwError $ TypeMismatch "string" (Value val)

unconsString :: PrimitiveFunc
unconsString = oneArg $ \val -> do
  case val of
    String str -> case T.uncons str of
                    Just (c, rest) ->  return $ Tuple [Char c, String rest]
                    Nothing -> throwError $ Default "Tried to unsnoc empty string"
    _ -> throwError $ TypeMismatch "string" (Value val)

lengthString :: PrimitiveFunc
lengthString = oneArg $ \val -> do
  case val of
    String str -> return . (\x -> Rational (x % 1)) . toInteger $ T.length str
    _ -> throwError $ TypeMismatch "string" (Value val)

appendString :: PrimitiveFunc
appendString = twoArgs $ \val1 val2 -> do
  case (val1, val2) of
    (String str1, String str2) -> return . String $ T.append str1 str2
    (String _, _) -> throwError $ TypeMismatch "string" (Value val2)
    (_, _) -> throwError $ TypeMismatch "string" (Value val1)

splitString :: PrimitiveFunc
splitString = twoArgs $ \pat src -> do
  case (pat, src) of
    (String patStr, String srcStr) -> return . Collection . Sq.fromList $ map String $ T.splitOn patStr srcStr
    (String _, _) -> throwError $ TypeMismatch "string" (Value src)
    (_, _) -> throwError $ TypeMismatch "string" (Value pat)

regexString :: PrimitiveFunc
regexString = twoArgs $ \pat src -> do
  case (pat, src) of
    (String patStr, String srcStr) -> do
      let (a, b, c) = (((T.unpack srcStr) =~ (T.unpack patStr)) :: (String, String, String))
      if b == ""
        then return . Collection . Sq.fromList $ []
        else return . Collection . Sq.fromList $ [Tuple [String $ T.pack a, String $ T.pack b, String $ T.pack c]]
    (String _, _) -> throwError $ TypeMismatch "string" (Value src)
    (_, _) -> throwError $ TypeMismatch "string" (Value pat)

regexStringCaptureGroup :: PrimitiveFunc
regexStringCaptureGroup = twoArgs $ \pat src -> do
  case (pat, src) of
    (String patStr, String srcStr) -> do
      let ret = (((T.unpack srcStr) =~ (T.unpack patStr)) :: [[String]])
      case ret of 
        [] -> return . Collection . Sq.fromList $ []
        ((x:xs):_) -> do let (a, c) = T.breakOn (T.pack x) srcStr
                         return . Collection . Sq.fromList $ [Tuple [String a, Collection (Sq.fromList (map (String . T.pack) xs)), String (T.drop (length x) c)]]
    (String _, _) -> throwError $ TypeMismatch "string" (Value src)
    (_, _) -> throwError $ TypeMismatch "string" (Value pat)

--regexStringMatch :: PrimitiveFunc
--regexStringMatch = twoArgs $ \pat src -> do
--  case (pat, src) of
--    (String patStr, String srcStr) -> return . Bool $ (((T.unpack srcStr) =~ (T.unpack patStr)) :: Bool)
--    (String _, _) -> throwError $ TypeMismatch "string" (Value src)
--    (_, _) -> throwError $ TypeMismatch "string" (Value pat)

readProcess' :: PrimitiveFunc
readProcess' = threeArgs $ \cmd args input -> do
  case (cmd, args, input) of
    (String cmdStr, Collection argStrs, String inputStr) -> do
      outputStr <- liftIO $ readProcess (T.unpack cmdStr) (map (\arg -> case arg of
                                                                          String argStr -> T.unpack argStr)
                                                                (toList argStrs)) (T.unpack inputStr)
      return (String (T.pack outputStr))
    (_, _, _) -> throwError $ TypeMismatch "(string, collection, string)" (Value (Tuple [cmd, args, input]))

read' :: PrimitiveFunc
read'= oneArg $ \val -> fromEgison val >>= readExpr . T.unpack >>= evalExprDeep nullEnv

readTSV :: PrimitiveFunc
readTSV= oneArg $ \val -> do rets <- fromEgison val >>= readExprs . T.unpack >>= mapM (evalExprDeep nullEnv)
                             case rets of
                               [ret] -> return ret
                               _ -> return (Tuple rets)

show' :: PrimitiveFunc
show'= oneArg $ \val -> return $ toEgison $ T.pack $ show val

showTSV' :: PrimitiveFunc
showTSV'= oneArg $ \val -> return $ toEgison $ T.pack $ showTSV val

--
-- Collection
--
isEmpty' :: PrimitiveFunc
isEmpty' whnf = do
  b <- isEmptyCollection whnf
  if b
    then return $ Value $ Bool True
    else return $ Value $ Bool False

uncons' :: PrimitiveFunc
uncons' whnf = do
  mRet <- runMaybeT (unconsCollection whnf)
  case mRet of
    Just (carObjRef, cdrObjRef) -> return $ Intermediate $ ITuple [carObjRef, cdrObjRef]
    Nothing -> throwError $ Default $ "cannot uncons collection"

unsnoc' :: PrimitiveFunc
unsnoc' whnf = do
  mRet <- runMaybeT (unsnocCollection whnf)
  case mRet of
    Just (racObjRef, rdcObjRef) -> return $ Intermediate $ ITuple [racObjRef, rdcObjRef]
    Nothing -> throwError $ Default $ "cannot unsnoc collection"

-- Typing

isBool :: PrimitiveFunc
isBool (Value (Bool _)) = return $ Value $ Bool True
isBool _ = return $ Value $ Bool False

isInteger :: PrimitiveFunc
isInteger (Value (Rational _)) = return $ Value $ Bool True
isInteger _ = return $ Value $ Bool False

isRational :: PrimitiveFunc
isRational (Value (Rational _)) = return $ Value $ Bool True
isRational _ = return $ Value $ Bool False

isFloat :: PrimitiveFunc
isFloat (Value (Float _)) = return $ Value $ Bool True
isFloat _ = return $ Value $ Bool False

isChar :: PrimitiveFunc
isChar (Value (Char _)) = return $ Value $ Bool True
isChar _ = return $ Value $ Bool False

isString :: PrimitiveFunc
isString (Value (String _)) = return $ Value $ Bool True
isString _ = return $ Value $ Bool False

isCollection :: PrimitiveFunc
isCollection (Value (Collection _)) = return $ Value $ Bool True
isCollection (Intermediate (ICollection _)) = return $ Value $ Bool True
isCollection _ = return $ Value $ Bool False

isArray :: PrimitiveFunc
isArray (Value (Array _)) = return $ Value $ Bool True
isArray (Intermediate (IArray _)) = return $ Value $ Bool True
isArray _ = return $ Value $ Bool False

isHash :: PrimitiveFunc
isHash (Value (IntHash _)) = return $ Value $ Bool True
isHash (Value (StrHash _)) = return $ Value $ Bool True
isHash (Intermediate (IIntHash _)) = return $ Value $ Bool True
isHash (Intermediate (IStrHash _)) = return $ Value $ Bool True
isHash _ = return $ Value $ Bool False

-- Test

assert ::  PrimitiveFunc
assert = twoArgs $ \label test -> do
  test <- fromEgison test
  if test
    then return $ Bool True
    else throwError $ Assertion $ show label

assertEqual :: PrimitiveFunc
assertEqual = threeArgs $ \label actual expected -> do
  if actual == expected
    then return $ Bool True
    else throwError $ Assertion $ show label ++ "\n expected: " ++ show expected ++
                                  "\n but found: " ++ show actual

--
-- IO Primitives
--

ioPrimitives :: [(String, PrimitiveFunc)]
ioPrimitives = [
                 ("return", return')
               , ("open-input-file", makePort ReadMode)
               , ("open-output-file", makePort WriteMode)
               , ("close-input-port", closePort)
               , ("close-output-port", closePort)
               , ("read-char", readChar)
               , ("read-line", readLine)
               , ("write-char", writeChar)
               , ("write", writeString)
                 
               , ("read-char-from-port", readCharFromPort)
               , ("read-line-from-port", readLineFromPort)
               , ("write-char-to-port", writeCharToPort)
               , ("write-to-port", writeStringToPort)
                 
               , ("eof?", isEOFStdin)
               , ("flush", flushStdout)
               , ("eof-port?", isEOFPort)
               , ("flush-port", flushPort)
               , ("read-file", readFile')
                 
               , ("rand", randRange)
--               , ("sqlite", sqlite)
               ]

makeIO :: EgisonM EgisonValue -> EgisonValue
makeIO m = IOFunc $ liftM (Value . Tuple . (World :) . (:[])) m

makeIO' :: EgisonM () -> EgisonValue
makeIO' m = IOFunc $ m >> return (Value $ Tuple [World, Tuple []])

return' :: PrimitiveFunc
return' = oneArg $ \val -> return $ makeIO $ return val

makePort :: IOMode -> PrimitiveFunc
makePort mode = oneArg $ \val -> do
  filename <- fromEgison val
  port <- liftIO $ openFile (T.unpack filename) mode
  return $ makeIO $ return (Port port)

closePort :: PrimitiveFunc
closePort = oneArg $ \val -> do
  port <- fromEgison val
  return $ makeIO' $ liftIO $ hClose port

writeChar :: PrimitiveFunc
writeChar = oneArg $ \val -> do
  c <- fromEgison val
  return $ makeIO' $ liftIO $ putChar c

writeCharToPort :: PrimitiveFunc
writeCharToPort = twoArgs $ \val val' -> do
  port <- fromEgison val
  c <- fromEgison val'
  return $ makeIO' $ liftIO $ hPutChar port c

writeString :: PrimitiveFunc
writeString = oneArg $ \val -> do
  s <- fromEgison val
  return $ makeIO' $ liftIO $ T.putStr s
  
writeStringToPort :: PrimitiveFunc
writeStringToPort = twoArgs $ \val val' -> do
  port <- fromEgison val
  s <- fromEgison val'
  return $ makeIO' $ liftIO $ T.hPutStr port s

flushStdout :: PrimitiveFunc
flushStdout = noArg $ return $ makeIO' $ liftIO $ hFlush stdout

flushPort :: PrimitiveFunc
flushPort = oneArg $ \val -> do
  port <- fromEgison val
  return $ makeIO' $ liftIO $ hFlush port

readChar :: PrimitiveFunc
readChar = noArg $ return $ makeIO $ liftIO $ liftM Char getChar

readCharFromPort :: PrimitiveFunc
readCharFromPort = oneArg $ \val -> do
  port <- fromEgison val
  c <- liftIO $ hGetChar port
  return $ makeIO $ return (Char c)

readLine :: PrimitiveFunc
readLine = noArg $ return $ makeIO $ liftIO $ liftM toEgison T.getLine

readLineFromPort :: PrimitiveFunc
readLineFromPort = oneArg $ \val -> do
  port <- fromEgison val
  s <- liftIO $ T.hGetLine port
  return $ makeIO $ return $ toEgison s

readFile' :: PrimitiveFunc
readFile' =  oneArg $ \val -> do
  filename <- fromEgison val
  s <- liftIO $ T.readFile $ T.unpack filename
  return $ makeIO $ return $ toEgison s
  
isEOFStdin :: PrimitiveFunc
isEOFStdin = noArg $ return $ makeIO $ liftIO $ liftM Bool isEOF

isEOFPort :: PrimitiveFunc
isEOFPort = oneArg $ \val -> do
  port <- fromEgison val
  b <- liftIO $ hIsEOF port
  return $ makeIO $ return (Bool b)

randRange :: PrimitiveFunc
randRange = twoArgs $ \val val' -> do
  r <- fromEgison val
  r' <- fromEgison val'
  n <- liftIO $ getStdRandom $ randomR ((numerator r), (numerator r'))
  return $ makeIO $ return $ Rational (n % 1)

 {-- -- for 'egison-sqlite'
sqlite :: PrimitiveFunc
sqlite  = twoArgs $ \val val' -> do
  dbName <- fromEgison val
  qStr <- fromEgison val'
  ret <- liftIO $ query' (T.pack dbName) $ T.pack qStr
  return $ makeIO $ return $ Collection $ Sq.fromList $ map (\r -> Tuple (map toEgison r)) ret
 where
  query' :: T.Text -> T.Text -> IO [[String]]
  query' dbName q = do
    db <- SQLite.open dbName
    rowsRef <- newIORef []
    SQLite.execWithCallback db q (\_ _ mcs -> do
                                    row <- forM mcs (\mcol -> case mcol of
                                                              Just col ->  return $ T.unpack col
                                                              Nothing -> return "null")
                                    rows <- readIORef rowsRef
                                    writeIORef rowsRef (row:rows))
    SQLite.close db
    ret <- readIORef rowsRef
    return $ reverse ret
 --} -- for 'egison-sqlite'
