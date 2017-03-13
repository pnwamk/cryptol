module Cryptol.TypeCheck.TypePat
  ( aInf, aNat, aNat'

  , anAdd, (|-|), aMul, (|^|), (|/|), (|%|)
  , aMin, aMax
  , aWidth
  , aLenFromThen, aLenFromThenTo

  , aTVar
  , aBit
  , aSeq
  , aWord
  , aChar
  , aTuple
  , (|->|)

  , aFin, (|=|), (|/=|), (|>=|)
  , aCmp, aArith

  , aAnd
  , aTrue

  , anError

  , module Cryptol.Utils.Patterns
  ) where

import Control.Applicative((<|>))
import Control.Monad
import Cryptol.Utils.Patterns
import Cryptol.TypeCheck.Type
import Cryptol.TypeCheck.Solver.InfNat


tcon :: TCon -> ([Type] -> a) -> Pat Type a
tcon f p = \ty -> case tNoUser ty of
                    TCon c ts | f == c -> return (p ts)
                    _                  -> mzero

ar0 :: [a] -> ()
ar0 ~[] = ()

ar1 :: [a] -> a
ar1 ~[a] = a

ar2 :: [a] -> (a,a)
ar2 ~[a,b] = (a,b)

ar3 :: [a] -> (a,a,a)
ar3 ~[a,b,c] = (a,b,c)

tf :: TFun -> ([Type] -> a) -> Pat Type a
tf f ar = tcon (TF f) ar

tc :: TC -> ([Type] -> a) -> Pat Type a
tc f ar = tcon (TC f) ar

tp :: PC -> ([Type] -> a) -> Pat Prop a
tp f ar = tcon (PC f) ar


--------------------------------------------------------------------------------

aInf :: Pat Type ()
aInf = tc TCInf ar0

aNat :: Pat Type Integer
aNat = \a -> case tNoUser a of
               TCon (TC (TCNum n)) _ -> return n
               _                     -> mzero

aNat' :: Pat Type Nat'
aNat' = \a -> (Inf <$  aInf a)
          <|> (Nat <$> aNat a)

anAdd :: Pat Type (Type,Type)
anAdd = tf TCAdd ar2

(|-|) :: Pat Type (Type,Type)
(|-|) = tf TCSub ar2

aMul :: Pat Type (Type,Type)
aMul = tf TCMul ar2

(|^|) :: Pat Type (Type,Type)
(|^|) = tf TCExp ar2

(|/|) :: Pat Type (Type,Type)
(|/|) = tf TCDiv ar2

(|%|) :: Pat Type (Type,Type)
(|%|) = tf TCMod ar2

aMin :: Pat Type (Type,Type)
aMin = tf TCMin ar2

aMax :: Pat Type (Type,Type)
aMax = tf TCMax ar2

aWidth :: Pat Type Type
aWidth = tf TCWidth ar1

aLenFromThen :: Pat Type (Type,Type,Type)
aLenFromThen = tf TCLenFromThen ar3

aLenFromThenTo :: Pat Type (Type,Type,Type)
aLenFromThenTo = tf TCLenFromThenTo ar3

--------------------------------------------------------------------------------
aTVar :: Pat Type TVar
aTVar = \a -> case tNoUser a of
                TVar x -> return x
                _      -> mzero

aBit :: Pat Type ()
aBit = tc TCBit ar0

aSeq :: Pat Type (Type,Type)
aSeq = tc TCSeq ar2

aWord :: Pat Type Type
aWord = \a -> do (l,t) <- aSeq a
                 aBit t
                 return l

aChar :: Pat Type ()
aChar = \a -> do (l,t) <- aSeq a
                 n     <- aNat l
                 guard (n == 8)
                 aBit t

aTuple :: Pat Type [Type]
aTuple = \a -> case tNoUser a of
                 TCon (TC (TCTuple _)) ts -> return ts
                 _                        -> mzero

(|->|) :: Pat Type (Type,Type)
(|->|) = tc TCFun ar2
--------------------------------------------------------------------------------

aFin :: Pat Prop Type
aFin = tp PFin ar1

(|=|) :: Pat Prop (Type,Type)
(|=|) = tp PEqual ar2

(|/=|) :: Pat Prop (Type,Type)
(|/=|) = tp PNeq ar2

(|>=|) :: Pat Prop (Type,Type)
(|>=|) = tp PGeq ar2

aCmp :: Pat Prop Type
aCmp = tp PCmp ar1

aArith :: Pat Prop Type
aArith = tp PArith ar1

aAnd :: Pat Prop (Prop,Prop)
aAnd = tp PAnd ar2

aTrue :: Pat Prop ()
aTrue = tp PTrue ar0

--------------------------------------------------------------------------------
anError :: Pat Type TCErrorMessage
anError = \a -> case tNoUser a of
                  TCon (TError _ err) _ -> return err
                  _                     -> mzero

