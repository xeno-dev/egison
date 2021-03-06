{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE TypeOperators         #-}

{- |
Module      : Language.Egison.Tensor
Licence     : MIT

This module contains functions for tensors.
-}

module Language.Egison.Tensor
    (
    -- * Tensor
      initTensor
    , tToList
    , tIndex
    , tref
    , enumTensorIndices
    , changeIndex
    , tTranspose
    , tTranspose'
    , tFlipIndices
    , appendDFscripts
    , removeDFscripts
    , tMap
    , tMap2
    , tMapN
    , tSum
    , tProduct
    , tContract
    , tContract'
    , tConcat
    , tConcat'
    ) where

import           Prelude                   hiding (foldr, mappend, mconcat)

import           Control.Monad.Except      hiding (join)
import qualified Data.Vector               as V
import           Data.List                 (delete, find, findIndex,
                                            partition, (\\))

import           Control.Egison            hiding (Integer)
import qualified Control.Egison            as M

import           Language.Egison.AST hiding (PatVar)
import           Language.Egison.Data
import           Language.Egison.IState     (fresh, getFuncNameStack)
import           Language.Egison.MathExpr

--
-- Tensors
--

initTensor :: Shape -> [a] -> Tensor a
initTensor ns xs = Tensor ns (V.fromList xs) []

tShape :: Tensor a -> Shape
tShape (Tensor ns _ _) = ns
tShape (Scalar _)      = []

tToList :: Tensor a -> [a]
tToList (Tensor _ xs _) = V.toList xs
tToList (Scalar x)      = [x]

tToVector :: Tensor a -> V.Vector a
tToVector (Tensor _ xs _) = xs
tToVector (Scalar x)      = V.fromList [x]

tIndex :: Tensor a -> [Index EgisonValue]
tIndex (Tensor _ _ js) = js
tIndex (Scalar _)      = []

tIntRef' :: HasTensor a => Integer -> Tensor a -> EgisonM a
tIntRef' i (Tensor [n] xs _) =
  if 0 < i && i <= n
     then fromTensor $ Scalar $ xs V.! fromIntegral (i - 1)
     else throwError =<< TensorIndexOutOfBounds i n <$> getFuncNameStack
tIntRef' i (Tensor (n:ns) xs js) =
  if 0 < i && i <= n
   then let w = fromIntegral (product ns) in
        let ys = V.take w (V.drop (w * fromIntegral (i - 1)) xs) in
          fromTensor $ Tensor ns ys (cdr js)
   else throwError =<< TensorIndexOutOfBounds i n <$> getFuncNameStack
tIntRef' _ _ = throwError $ Default "More indices than the order of the tensor"

tIntRef :: HasTensor a => [Integer] -> Tensor a -> EgisonM (Tensor a)
tIntRef [] (Tensor [] xs _)
  | V.length xs == 1 = return $ Scalar (xs V.! 0)
  | otherwise = throwError =<< EgisonBug "sevaral elements in scalar tensor" <$> getFuncNameStack
tIntRef [] t = return t
tIntRef (m:ms) t = tIntRef' m t >>= toTensor >>= tIntRef ms

-- TODO(momohatt): Refactor.
tref :: HasTensor a => [Index EgisonValue] -> Tensor a -> EgisonM a
tref [] (Tensor [] xs _)
  | V.length xs == 1 = fromTensor $ Scalar (xs V.! 0)
  | otherwise = throwError =<< EgisonBug "sevaral elements in scalar tensor" <$> getFuncNameStack
tref [] t = fromTensor t
tref (Subscript    (ScalarData (SingleTerm m [])):ms) t                  = tIntRef' m t >>= toTensor >>= tref ms
tref (Subscript    (ScalarData (Div (Plus []) (Plus [Term 1 []]))):ms) t = tIntRef' 0 t >>= toTensor >>= tref ms
tref (Superscript  (ScalarData (SingleTerm m [])):ms) t                  = tIntRef' m t >>= toTensor >>= tref ms
tref (Superscript  (ScalarData (Div (Plus []) (Plus [Term 1 []]))):ms) t = tIntRef' 0 t >>= toTensor >>= tref ms
tref (SupSubscript (ScalarData (SingleTerm m [])):ms) t                  = tIntRef' m t >>= toTensor >>= tref ms
tref (SupSubscript (ScalarData (Div (Plus []) (Plus [Term 1 []]))):ms) t = tIntRef' 0 t >>= toTensor >>= tref ms
tref (Subscript (Tuple [mVal, nVal]):ms) t@(Tensor is _ _) = do
  m <- fromEgison mVal
  n <- fromEgison nVal
  if m > n
    then
      fromTensor (Tensor (replicate (length is) 0) V.empty [])
    else do
      ts <- mapM (\i -> tIntRef' i t >>= toTensor >>= tref ms >>= toTensor) [m..n]
      symId <- fresh
      tConcat (Subscript (symbolScalarData "" (":::" ++ symId))) ts >>= fromTensor
tref (Superscript (Tuple [mVal, nVal]):ms) t@(Tensor is _ _) = do
  m <- fromEgison mVal
  n <- fromEgison nVal
  if m > n
    then
      fromTensor (Tensor (replicate (length is) 0) V.empty [])
    else do
      ts <- mapM (\i -> tIntRef' i t >>= toTensor >>= tref ms >>= toTensor) [m..n]
      symId <- fresh
      tConcat (Superscript (symbolScalarData "" (":::" ++ symId))) ts >>= fromTensor
tref (SupSubscript (Tuple [mVal, nVal]):ms) t@(Tensor is _ _) = do
  m <- fromEgison mVal
  n <- fromEgison nVal
  if m > n
    then
      fromTensor (Tensor (replicate (length is) 0) V.empty [])
    else do
      ts <- mapM (\i -> tIntRef' i t >>= toTensor >>= tref ms >>= toTensor) [m..n]
      symId <- fresh
      tConcat (SupSubscript (symbolScalarData "" (":::" ++ symId))) ts >>= fromTensor
tref (s:ms) (Tensor (_:ns) xs js) = do
  let yss = split (product ns) xs
  ts <- mapM (\ys -> tref ms (Tensor ns ys (cdr js))) yss
  mapM toTensor ts >>= tConcat s >>= fromTensor
tref _ _ = throwError $ Default "More indices than the order of the tensor"

-- Enumarates all indices (1-indexed) from shape
-- ex.
-- >>> enumTensorIndices [2,2,2]
-- [[1,1,1],[1,1,2],[1,2,1],[1,2,2],[2,1,1],[2,1,2],[2,2,1],[2,2,2]]
enumTensorIndices :: Shape -> [[Integer]]
enumTensorIndices [] = [[]]
enumTensorIndices (n:ns) = concatMap (\i -> map (i:) (enumTensorIndices ns)) [1..n]

changeIndex :: Index String -> EgisonValue -> Index String
changeIndex (Superscript s) m = Superscript (s ++ show m)
changeIndex (Subscript s) m   = Subscript (s ++ show m)

-- transIndex [a, b, c] [c, a, b] [2, 3, 4] = [4, 2, 3]
transIndex :: [Index EgisonValue] -> [Index EgisonValue] -> [Integer] -> EgisonM [Integer]
transIndex is js ns = do
  mapM (\j -> matchDFS (zip is ns) (List (Pair Eql M.Something))
               [[mc| _ ++ (#j, $n) : _ -> return n |]
               ,[mc| _ -> throwError $ Default "cannot transpose becuase of the inconsitent symbolic tensor indices" |]])
       js

tTranspose :: HasTensor a => [Index EgisonValue] -> Tensor a -> EgisonM (Tensor a)
tTranspose is t@(Tensor ns _ js) =
  if length is <= length js
    then do let js' = take (length is) js
            let k = fromIntegral (length ns - length is)
            let ds = map (DFscript 0) [1..k]
            ns' <- transIndex (js' ++ ds) (is ++ ds) ns
            xs' <- V.fromList <$> mapM (transIndex (is ++ ds) (js' ++ ds)) (enumTensorIndices ns') >>= mapM (`tIntRef` t) >>= mapM fromTensor
            return $ Tensor ns' xs' is
    else return t

tTranspose' :: HasTensor a => [EgisonValue] -> Tensor a -> EgisonM (Tensor a)
tTranspose' is t@(Tensor _ _ js) = do
  case g is js of
    Nothing -> return t
    Just is' -> tTranspose is' t
 where
  f :: Index EgisonValue -> EgisonValue
  f (Subscript i)    = i
  f (Superscript i)  = i
  f (SupSubscript i) = i
  g :: [EgisonValue] -> [Index EgisonValue] -> Maybe [Index EgisonValue]
  g [] _ = return []
  g (i:is) js = case find (\j -> i == f j) js of
                  Nothing -> Nothing
                  Just j' -> do js' <- g is js
                                return $ j':js'

tFlipIndices :: HasTensor a => Tensor a -> EgisonM (Tensor a)
tFlipIndices (Tensor ns xs js) = return $ Tensor ns xs (map flipIndex js)
 where
  flipIndex (Subscript i)   = Superscript i
  flipIndex (Superscript i) = Subscript i
  flipIndex x               = x

appendDFscripts :: Integer -> WHNFData -> EgisonM WHNFData
appendDFscripts id (Intermediate (ITensor (Tensor s xs is))) = do
  let k = fromIntegral (length s - length is)
  return $ Intermediate (ITensor (Tensor s xs (is ++ map (DFscript id) [1..k])))
appendDFscripts id (Value (TensorData (Tensor s xs is))) = do
  let k = fromIntegral (length s - length is)
  return $ Value (TensorData (Tensor s xs (is ++ map (DFscript id) [1..k])))
appendDFscripts _ whnf = return whnf

removeDFscripts :: WHNFData -> EgisonM WHNFData
removeDFscripts (Intermediate (ITensor (Tensor s xs is))) = do
  let (ds, js) = partition isDF is
  Tensor s ys _ <- tTranspose (js ++ ds) (Tensor s xs is)
  return (Intermediate (ITensor (Tensor s ys js)))
 where
  isDF (DFscript _ _) = True
  isDF _              = False
removeDFscripts (Value (TensorData (Tensor s xs is))) = do
  let (ds, js) = partition isDF is
  Tensor s ys _ <- tTranspose (js ++ ds) (Tensor s xs is)
  return (Value (TensorData (Tensor s ys js)))
 where
  isDF (DFscript _ _) = True
  isDF _              = False
removeDFscripts whnf = return whnf

tMap :: HasTensor a => (a -> EgisonM a) -> Tensor a -> EgisonM (Tensor a)
tMap f (Tensor ns xs js') = do
  let k = fromIntegral $ length ns - length js'
  let js = js' ++ map (DFscript 0) [1..k]
  xs' <- V.fromList <$> mapM f (V.toList xs)
  t <- toTensor (V.head xs')
  case t of
    Tensor ns1 _ js1' -> do
      let k1 = fromIntegral $ length ns1 - length js1'
      let js1 = js1' ++ map (DFscript 0) [1..k1]
      tContract' $ Tensor (ns ++ ns1) (V.concat (V.toList (V.map tensorElems xs'))) (js ++ js1)
    _ -> return $ Tensor ns xs' js
tMap f (Scalar x) = Scalar <$> f x

tMapN :: HasTensor a => ([a] -> EgisonM a) -> [Tensor a] -> EgisonM (Tensor a)
tMapN f ts@(Tensor ns _ js : _) = do
  xs' <- mapM (\is -> mapM (tIntRef is) ts >>= mapM fromTensor >>= f) (enumTensorIndices ns)
  return $ Tensor ns (V.fromList xs') js
tMapN f xs = Scalar <$> (mapM fromTensor xs >>= f)

tMap2 :: HasTensor a => (a -> a -> EgisonM a) -> Tensor a -> Tensor a -> EgisonM (Tensor a)
tMap2 f (Tensor ns1 xs1 js1') (Tensor ns2 xs2 js2') = do
  let k1 = fromIntegral $ length ns1 - length js1'
  let js1 = js1' ++ map (DFscript 0) [1..k1]
  let k2 = fromIntegral $ length ns2 - length js2'
  let js2 = js2' ++ map (DFscript 0) [1..k2]
  let (cjs, tjs1, tjs2) = h js1 js2
  t1' <- tTranspose (cjs ++ tjs1) (Tensor ns1 xs1 js1)
  t2' <- tTranspose (cjs ++ tjs2) (Tensor ns2 xs2 js2)
  let cns = take (length cjs) (tShape t1')
  rts1 <- mapM (`tIntRef` t1') (enumTensorIndices cns)
  rts2 <- mapM (`tIntRef` t2') (enumTensorIndices cns)
  rts' <- zipWithM (tProduct f) rts1 rts2
  let ret = Tensor (cns ++ tShape (head rts')) (V.concat (map tToVector rts')) (cjs ++ tIndex (head rts'))
  tTranspose (uniq (tDiagIndex (js1 ++ js2))) ret
 where
  h :: [Index EgisonValue] -> [Index EgisonValue] -> ([Index EgisonValue], [Index EgisonValue], [Index EgisonValue])
  h js1 js2 = let cjs = filter (`elem` js2) js1 in
                (cjs, js1 \\ cjs, js2 \\ cjs)
  uniq :: [Index EgisonValue] -> [Index EgisonValue]
  uniq []     = []
  uniq (x:xs) = x:uniq (delete x xs)
tMap2 f t@Tensor{} (Scalar x) = tMap (`f` x) t
tMap2 f (Scalar x) t@Tensor{} = tMap (f x) t
tMap2 f (Scalar x1) (Scalar x2) = Scalar <$> f x1 x2

tDiag :: HasTensor a => Tensor a -> EgisonM (Tensor a)
tDiag t@(Tensor _ _ js) =
  case filter (\j -> any (p j) js) js of
    [] -> return t
    xs -> do
      let ys = js \\ (xs ++ map reverseIndex xs)
      t2 <- tTranspose (xs ++ map reverseIndex xs ++ ys) t
      let (ns1, tmp) = splitAt (length xs) (tShape t2)
      let (_, ns2) = splitAt (length xs) tmp
      ts <- mapM (\is -> tIntRef (is ++ is) t2) (enumTensorIndices ns1)
      return $ Tensor (ns1 ++ ns2) (V.concat (map tToVector ts)) (map toSupSubscript xs ++ ys)
 where
  p :: Index EgisonValue -> Index EgisonValue -> Bool
  p (Superscript i) (Subscript j) = i == j
  p (Subscript _) _               = False
  p _ _                           = False
tDiag t = return t

tDiagIndex :: [Index EgisonValue] -> [Index EgisonValue]
tDiagIndex js =
  let xs = filter (\j -> any (p j) js) js
      ys = js \\ (xs ++ map reverseIndex xs)
   in map toSupSubscript xs ++ ys
 where
  p :: Index EgisonValue -> Index EgisonValue -> Bool
  p (Superscript i) (Subscript j) = i == j
  p (Subscript _) _               = False
  p _ _                           = False

tSum :: HasTensor a => (a -> a -> EgisonM a) -> Tensor a -> Tensor a -> EgisonM (Tensor a)
tSum f (Tensor ns1 xs1 js1) t2@Tensor{} = do
  t2' <- tTranspose js1 t2
  case t2' of
    (Tensor ns2 xs2 _)
      | ns2 == ns1 -> do ys <- V.mapM (uncurry f) (V.zip xs1 xs2)
                         return (Tensor ns1 ys js1)
      | otherwise -> throwError =<< InconsistentTensorShape <$> getFuncNameStack

tProduct :: HasTensor a => (a -> a -> EgisonM a) -> Tensor a -> Tensor a -> EgisonM (Tensor a)
tProduct f (Tensor ns1 xs1 js1') (Tensor ns2 xs2 js2') = do
  let k1 = fromIntegral $ length ns1 - length js1'
  let js1 = js1' ++ map (DFscript 0) [1..k1]
  let k2 = fromIntegral $ length ns2 - length js2'
  let js2 = js2' ++ map (DFscript 0) [1..k2]
  let (cjs1, cjs2, tjs1, tjs2) = h js1 js2
  let t1 = Tensor ns1 xs1 js1
  let t2 = Tensor ns2 xs2 js2
  case cjs1 of
    [] -> do
      xs' <- V.fromList <$> mapM (\is -> do
                              let is1 = take (length ns1) is
                              let is2 = take (length ns2) (drop (length ns1) is)
                              x1 <- tIntRef is1 t1 >>= fromTensor
                              x2 <- tIntRef is2 t2 >>= fromTensor
                              f x1 x2) (enumTensorIndices (ns1 ++ ns2))
      tContract' (Tensor (ns1 ++ ns2) xs' (js1 ++ js2))
    _ -> do
      t1' <- tTranspose (cjs1 ++ tjs1) t1
      t2' <- tTranspose (cjs2 ++ tjs2) t2
      let (cns1, _) = splitAt (length cjs1) (tShape t1')
      rts' <- mapM (\is -> do rt1 <- tIntRef is t1'
                              rt2 <- tIntRef is t2'
                              tProduct f rt1 rt2) (enumTensorIndices cns1)
      let ret = Tensor (cns1 ++ tShape (head rts')) (V.concat (map tToVector rts')) (map toSupSubscript cjs1 ++ tIndex (head rts'))
      tTranspose (uniq (map toSupSubscript cjs1 ++ tjs1 ++ tjs2)) ret
 where
  h :: [Index EgisonValue] -> [Index EgisonValue] -> ([Index EgisonValue], [Index EgisonValue], [Index EgisonValue], [Index EgisonValue])
  h js1 js2 = let cjs = filter (\j -> any (p j) js2) js1 in
                (cjs, map reverseIndex cjs, js1 \\ cjs, js2 \\ map reverseIndex cjs)
  p :: Index EgisonValue -> Index EgisonValue -> Bool
  p (Superscript i) (Subscript j) = i == j
  p (Subscript i) (Superscript j) = i == j
  p _ _                           = False
  uniq :: [Index EgisonValue] -> [Index EgisonValue]
  uniq []     = []
  uniq (x:xs) = x:uniq (delete x xs)
tProduct f (Scalar x) (Tensor ns xs js) = do
  xs' <- V.mapM (f x) xs
  return $ Tensor ns xs' js
tProduct f (Tensor ns xs js) (Scalar x) = do
  xs' <- V.mapM (`f` x) xs
  return $ Tensor ns xs' js
tProduct f (Scalar x1) (Scalar x2) = Scalar <$> f x1 x2

tContract :: HasTensor a => Tensor a -> EgisonM [Tensor a]
tContract t = do
  t' <- tDiag t
  case t' of
    (Tensor (n:_) _ (SupSubscript _ : _)) -> do
      ts <- mapM (`tIntRef'` t') [1..n]
      tss <- mapM toTensor ts >>= mapM tContract
      return $ concat tss
    _ -> return [t']

-- TODO: refactor in PMOP
tContract' :: HasTensor a => Tensor a -> EgisonM (Tensor a)
tContract' t@(Tensor ns _ js) =
  case findPair p js of
    Nothing -> return t
    Just (m, n) -> do
      let (hjs, mjs, tjs) = removePair (m,n) js
      xs' <- mapM (\i -> tref (hjs ++ [Subscript (ScalarData (SingleTerm i []))] ++ mjs
                                   ++ [Subscript (ScalarData (SingleTerm i []))] ++ tjs) t)
                  [1..(ns !! m)]
      mapM toTensor xs' >>= tConcat (js !! m) >>= tTranspose (hjs ++ [js !! m] ++ mjs ++ tjs) >>= tContract'
 where
  p :: Index EgisonValue -> Index EgisonValue -> Bool
  p (Superscript i) (Superscript j)   = i == j
  p (Subscript i) (Subscript j)       = i == j
  p (DFscript i1 j1) (DFscript i2 j2) = (i1 == i2) && (j1 == j2)
  p _ _                               = False
tContract' val = return val

tConcat :: HasTensor a => Index EgisonValue -> [Tensor a] -> EgisonM (Tensor a)
tConcat s (Tensor ns@(0:_) _ js:_) = return $ Tensor (0:ns) V.empty (s:js)
tConcat s ts@(Tensor ns _ js:_) = return $ Tensor (fromIntegral (length ts):ns) (V.concat (map tToVector ts)) (s:js)
tConcat s ts = do
  ts' <- mapM getScalar ts
  return $ Tensor [fromIntegral (length ts)] (V.fromList ts') [s]

tConcat' :: HasTensor a => [Tensor a] -> EgisonM (Tensor a)
tConcat' (Tensor ns@(0:_) _ _ : _) = return $ Tensor (0:ns) V.empty []
tConcat' ts@(Tensor ns _ _ : _) = return $ Tensor (fromIntegral (length ts):ns) (V.concat (map tToVector ts)) []
tConcat' ts = do
  ts' <- mapM getScalar ts
  return $ Tensor [fromIntegral (length ts)] (V.fromList ts') []


-- utility functions for tensors

cdr :: [a] -> [a]
cdr []     = []
cdr (_:ts) = ts

split :: Integer -> V.Vector a -> [V.Vector a]
split w xs
 | V.null xs = []
 | otherwise = let (hs, ts) = V.splitAt (fromIntegral w) xs in
                 hs:split w ts

getScalar :: Tensor a -> EgisonM a
getScalar (Scalar x) = return x
getScalar _          = throwError $ Default "Inconsitent Tensor order"

findPair :: (a -> a -> Bool) -> [a] -> Maybe (Int, Int)
findPair p xs = findPair' 0 p xs

-- TODO: refactor in PMOP
findPair' :: Int -> (a -> a -> Bool) -> [a] -> Maybe (Int, Int)
findPair' _ _ [] = Nothing
findPair' m p (x:xs) = case findIndex (p x) xs of
                    Just i  -> Just (m, m + i + 1)
                    Nothing -> findPair' (m + 1) p xs

-- TODO: refactor in PMOP
removePair :: (Int, Int) -> [a] -> ([a],[a],[a])
removePair (m, n) xs =          -- (0,1) [i i]
  let (hms, tts) = splitAt n xs  -- [i] [i]
      ts = tail tts              -- []
      (hs, tms) = splitAt m hms  -- [] [i]
      ms = tail tms              -- []
   in (hs, ms, ts)               -- [] [] []

reverseIndex :: Index EgisonValue -> Index EgisonValue
reverseIndex (Superscript i) = Subscript i
reverseIndex (Subscript i)   = Superscript i

toSupSubscript :: Index EgisonValue -> Index EgisonValue
toSupSubscript (Superscript i) = SupSubscript i
toSupSubscript (Subscript i)   = SupSubscript i
