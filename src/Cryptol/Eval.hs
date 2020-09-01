-- |
-- Module      :  Cryptol.Eval
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}

module Cryptol.Eval (
    moduleEnv
  , runEval
  , EvalOpts(..)
  , PPOpts(..)
  , defaultPPOpts
  , Eval
  , EvalEnv
  , emptyEnv
  , evalExpr
  , evalDecls
  , evalSel
  , evalSetSel
  , EvalError(..)
  , Unsupported(..)
  , forceValue
  ) where

import Cryptol.Eval.Backend
import Cryptol.Eval.Concrete( Concrete(..) )
import Cryptol.Eval.Env
import Cryptol.Eval.Monad
import Cryptol.Eval.Type
import Cryptol.Eval.Value
import Cryptol.ModuleSystem.Name
import Cryptol.Parser.Selector(ppSelector)
import Cryptol.TypeCheck.AST
import Cryptol.TypeCheck.Solver.InfNat(Nat'(..))
import Cryptol.Utils.Ident
import Cryptol.Utils.Panic (panic)
import Cryptol.Utils.PP
import Cryptol.Utils.RecordMap

import           Control.Monad
import           Data.List
import           Data.Maybe
import qualified Data.Map.Strict as Map
import           Data.Semigroup

import Prelude ()
import Prelude.Compat


type EvalEnv = GenEvalEnv Concrete

type EvalPrims sym =
  ( Backend sym, ?evalPrim :: PrimIdent -> Maybe (GenValue sym) )

type ConcPrims =
  ?evalPrim :: PrimIdent -> Maybe (GenValue Concrete)

-- Expression Evaluation -------------------------------------------------------

{-# SPECIALIZE moduleEnv ::
  ConcPrims =>
  Concrete ->
  Module ->
  GenEvalEnv Concrete ->
  SEval Concrete (GenEvalEnv Concrete)
  #-}

-- | Extend the given evaluation environment with all the declarations
--   contained in the given module.
moduleEnv ::
  EvalPrims sym =>
  sym ->
  Module         {- ^ Module containing declarations to evaluate -} ->
  GenEvalEnv sym {- ^ Environment to extend -} ->
  SEval sym (GenEvalEnv sym)
moduleEnv sym m env = evalDecls sym (mDecls m) =<< evalNewtypes sym (mNewtypes m) env

{-# SPECIALIZE evalExpr ::
  ConcPrims =>
  Concrete ->
  GenEvalEnv Concrete ->
  Expr ->
  SEval Concrete (GenValue Concrete)
  #-}

-- | Evaluate a Cryptol expression to a value.  This evaluator is parameterized
--   by the `EvalPrims` class, which defines the behavior of bits and words, in
--   addition to providing implementations for all the primitives.
evalExpr ::
  EvalPrims sym =>
  sym ->
  GenEvalEnv sym  {- ^ Evaluation environment -} ->
  Expr          {- ^ Expression to evaluate -} ->
  SEval sym (GenValue sym)
--evalExpr sym env expr = trace (show (ppPrec 0 expr)) $ case expr of
evalExpr sym env expr = case expr of

  -- Try to detect when the user has directly written a finite sequence of
  -- literal bit values and pack these into a word.
  EList es ty
    -- NB, even if the list cannot be packed, we must use `VWord`
    -- when the element type is `Bit`.
    | isTBit tyv
    -> {-# SCC "evalExpr->Elist/bit" #-}
       (tryFromBits sym vs >>= \case
         Just w -> VSeq (Nat (wordLen sym w)) TVBit <$> unpackSeqMap sym w
         Nothing -> do
            xs <- mapM (sDelay sym Nothing) vs
            VSeq (Nat len) TVBit <$> finiteSeqMap sym xs)

    | otherwise -> {-# SCC "evalExpr->EList" #-} do
        xs <- mapM (sDelay sym Nothing) vs
        VSeq (Nat len) tyv <$> finiteSeqMap sym xs
   where
    {-# INLINE tyv #-}
    tyv = evalValType (envTypes env) ty
    {-# INLINE vs #-}
    vs  = map eval es
    {-# INLINE len #-}
    len = genericLength es

  ETuple es -> {-# SCC "evalExpr->ETuple" #-} do
     xs <- mapM (sDelay sym Nothing . eval) es
     return $ VTuple xs

  ERec fields -> {-# SCC "evalExpr->ERec" #-} do
     xs <- traverse (sDelay sym Nothing . eval) fields
     return $ VRecord xs

  ESel e sel -> {-# SCC "evalExpr->ESel" #-} do
     e' <- eval e
     evalSel sym e' sel

  ESet ty e sel v -> {-# SCC "evalExpr->ESet" #-}
    do e' <- sDelay sym Nothing (eval e)
       let tyv = evalValType (envTypes env) ty
       evalSetSel sym tyv e' sel (eval v)

  EIf ty c t f -> {-# SCC "evalExpr->EIf" #-} do
     b <- fromVBit <$> eval c
     let tyv = evalValType (envTypes env) ty
     iteValue sym tyv b (eval t) (eval f)

  EComp n t h gs -> {-# SCC "evalExpr->EComp" #-} do
      let len  = evalNumType (envTypes env) n
      let elty = evalValType (envTypes env) t
      evalComp sym env len elty h gs

  EVar n -> {-# SCC "evalExpr->EVar" #-} do
    case lookupVar n env of
      Just val -> val
      Nothing  -> do
        envdoc <- ppEnv sym defaultPPOpts env
        panic "[Eval] evalExpr"
                     ["var `" ++ show (pp n) ++ "` is not defined"
                     , show envdoc
                     ]

  ETAbs tv b -> {-# SCC "evalExpr->ETAbs" #-}
    case tpKind tv of
      KType -> return $ VPoly    $ \ty -> evalExpr sym (bindType (tpVar tv) (Right ty) env) b
      KNum  -> return $ VNumPoly $ \n  -> evalExpr sym (bindType (tpVar tv) (Left n) env) b
      k     -> panic "[Eval] evalExpr" ["invalid kind on type abstraction", show k]

  ETApp e ty -> {-# SCC "evalExpr->ETApp" #-} do
    eval e >>= \case
      VPoly f     -> f $! (evalValType (envTypes env) ty)
      VNumPoly f  -> f $! (evalNumType (envTypes env) ty)
      _ -> panic "[Eval] evalExpr"
               ["expected a polymorphic value"
               , show (pp e), show (pp ty)
               ]

  EApp f v -> {-# SCC "evalExpr->EApp" #-} do
    eval f >>= \case
      VFun f' -> f' (eval v)
      _      -> panic "[Eval] evalExpr" ["not a function", show (pp f) ]

  EAbs n _ty b -> {-# SCC "evalExpr->EAbs" #-}
    return $ VFun (\v -> do env' <- bindVar sym n v env
                            evalExpr sym env' b)

  -- XXX these will likely change once there is an evidence value
  EProofAbs _ e -> eval e
  EProofApp e   -> eval e

  EWhere e ds -> {-# SCC "evalExpr->EWhere" #-} do
     env' <- evalDecls sym ds env
     evalExpr sym env' e

  where

  {-# INLINE eval #-}
  eval = evalExpr sym env

-- Newtypes --------------------------------------------------------------------

{-# SPECIALIZE evalNewtypes ::
  ConcPrims =>
  Concrete ->
  Map.Map Name Newtype ->
  GenEvalEnv Concrete ->
  SEval Concrete (GenEvalEnv Concrete)
  #-}

evalNewtypes ::
  EvalPrims sym =>
  sym ->
  Map.Map Name Newtype ->
  GenEvalEnv sym ->
  SEval sym (GenEvalEnv sym)
evalNewtypes sym nts env = foldM (flip (evalNewtype sym)) env $ Map.elems nts

-- | Introduce the constructor function for a newtype.
evalNewtype ::
  EvalPrims sym =>
  sym ->
  Newtype ->
  GenEvalEnv sym ->
  SEval sym (GenEvalEnv sym)
evalNewtype sym nt = bindVar sym (ntName nt) (return (foldr tabs con (ntParams nt)))
  where
  tabs _tp body = tlam (\ _ -> body)
  con           = VFun id
{-# INLINE evalNewtype #-}


-- Declarations ----------------------------------------------------------------

{-# SPECIALIZE evalDecls ::
  ConcPrims =>
  Concrete ->
  [DeclGroup] ->
  GenEvalEnv Concrete ->
  SEval Concrete (GenEvalEnv Concrete)
  #-}

-- | Extend the given evaluation environment with the result of evaluating the
--   given collection of declaration groups.
evalDecls ::
  EvalPrims sym =>
  sym ->
  [DeclGroup]   {- ^ Declaration groups to evaluate -} ->
  GenEvalEnv sym  {- ^ Environment to extend -} ->
  SEval sym (GenEvalEnv sym)
evalDecls x dgs env = foldM (evalDeclGroup x) env dgs

{-# SPECIALIZE evalDeclGroup ::
  ConcPrims =>
  Concrete ->
  GenEvalEnv Concrete ->
  DeclGroup ->
  SEval Concrete (GenEvalEnv Concrete)
  #-}

evalDeclGroup ::
  EvalPrims sym =>
  sym ->
  GenEvalEnv sym ->
  DeclGroup ->
  SEval sym (GenEvalEnv sym)
evalDeclGroup sym env dg = do
  case dg of
    Recursive ds -> do
      -- declare a "hole" for each declaration
      -- and extend the evaluation environment
      holes <- mapM (declHole sym) ds
      let holeEnv = Map.fromList $ [ (nm,h) | (nm,_,h,_) <- holes ]
      let env' = env `mappend` emptyEnv{ envVars = holeEnv }

      -- evaluate the declaration bodies, building a new evaluation environment
      env'' <- foldM (evalDecl sym env') env ds

      -- now backfill the holes we declared earlier using the definitions
      -- calculated in the previous step
      mapM_ (fillHole sym env'') holes

      -- return the map containing the holes
      return env'

    NonRecursive d -> do
      evalDecl sym env env d



{-# SPECIALIZE fillHole ::
  Concrete ->
  GenEvalEnv Concrete ->
  (Name, Schema, SEval Concrete (GenValue Concrete), SEval Concrete (GenValue Concrete) -> SEval Concrete ()) ->
  SEval Concrete ()
  #-}

-- | This operation is used to complete the process of setting up recursive declaration
--   groups.  It 'backfills' previously-allocated thunk values with the actual evaluation
--   procedure for the body of recursive definitions.
--
--   In order to faithfully evaluate the nonstrict semantics of Cryptol, we have to take some
--   care in this process.  In particular, we need to ensure that every recursive definition
--   binding is indistinguishable from its eta-expanded form.  The straightforward solution
--   to this is to force an eta-expansion procedure on all recursive definitions.
--   However, for the so-called 'Value' types we can instead optimistically use the 'delayFill'
--   operation and only fall back on full eta expansion if the thunk is double-forced.

fillHole ::
  Backend sym =>
  sym ->
  GenEvalEnv sym ->
  (Name, Schema, SEval sym (GenValue sym), SEval sym (GenValue sym) -> SEval sym ()) ->
  SEval sym ()
fillHole _sym env (nm, _, _, fill) = do
  case lookupVar nm env of
    Nothing -> evalPanic "fillHole" ["Recursive definition not completed", show (ppLocName nm)]
    Just v  -> fill v


{-# SPECIALIZE declHole ::
  Concrete ->
  Decl ->
  SEval Concrete
    (Name, Schema, SEval Concrete (GenValue Concrete), SEval Concrete (GenValue Concrete) -> SEval Concrete ())
  #-}

declHole ::
  Backend sym =>
  sym -> Decl -> SEval sym (Name, Schema, SEval sym (GenValue sym), SEval sym (GenValue sym) -> SEval sym ())
declHole sym d =
  case dDefinition d of
    DPrim   -> evalPanic "Unexpected primitive declaration in recursive group"
                         [show (ppLocName nm)]
    DExpr _ -> do
      (hole, fill) <- sDeclareHole sym msg
      return (nm, sch, hole, fill)
  where
  nm = dName d
  sch = dSignature d
  msg = unwords ["<<loop>> while evaluating", show (pp nm)]


-- | Evaluate a declaration, extending the evaluation environment.
--   Two input environments are given: the first is an environment
--   to use when evaluating the body of the declaration; the second
--   is the environment to extend.  There are two environments to
--   handle the subtle name-binding issues that arise from recursive
--   definitions.  The 'read only' environment is used to bring recursive
--   names into scope while we are still defining them.
evalDecl ::
  EvalPrims sym =>
  sym ->
  GenEvalEnv sym  {- ^ A 'read only' environment for use in declaration bodies -} ->
  GenEvalEnv sym  {- ^ An evaluation environment to extend with the given declaration -} ->
  Decl            {- ^ The declaration to evaluate -} ->
  SEval sym (GenEvalEnv sym)
evalDecl sym renv env d =
  case dDefinition d of
    DPrim ->
      case ?evalPrim =<< asPrim (dName d) of
        Just v  -> pure (bindVarDirect (dName d) v env)
        Nothing -> bindVar sym (dName d) (cryNoPrimError sym (dName d)) env

    DExpr e -> bindVar sym (dName d) (evalExpr sym renv e) env


-- Selectors -------------------------------------------------------------------

{-# SPECIALIZE evalSel ::
  ConcPrims =>
  Concrete ->
  GenValue Concrete ->
  Selector ->
  SEval Concrete (GenValue Concrete)
  #-}

-- | Apply the the given "selector" form to the given value.  This function pushes
--   tuple and record selections pointwise down into other value constructs
--   (e.g., streams and functions).
evalSel ::
  EvalPrims sym =>
  sym ->
  GenValue sym ->
  Selector ->
  SEval sym (GenValue sym)
evalSel sym val sel = case sel of

  TupleSel n _  -> tupleSel n val
  RecordSel n _ -> recordSel n val
  ListSel ix _  -> listSel ix val
  where

  tupleSel n v =
    case v of
      VTuple vs       -> vs !! n
      _               -> evalPanic "Cryptol.Eval.evalSel"
                            [ "Unexpected value in tuple selection" ]


  recordSel n v =
    case v of
      VRecord {}      -> lookupRecord n v
      _               ->  evalPanic "Cryptol.Eval.evalSel"
                            [ "Unexpected value in record selection" ]

  listSel n v =
    case v of
      VSeq _ _ vs     -> lookupSeqMap sym (toInteger n) vs
      _               -> evalPanic "Cryptol.Eval.evalSel"
                            [ "Unexpected value in list selection" ]

{-# SPECIALIZE evalSetSel ::
  ConcPrims =>
  Concrete -> TValue ->
  SEval Concrete (GenValue Concrete) ->
  Selector ->
  SEval Concrete (GenValue Concrete) ->
  SEval Concrete (GenValue Concrete)
  #-}
evalSetSel :: forall sym.
  EvalPrims sym =>
  sym ->
  TValue ->
  SEval sym (GenValue sym) ->
  Selector ->
  SEval sym (GenValue sym) ->
  SEval sym (GenValue sym)
evalSetSel sym tyv e sel v =
  case (tyv, sel) of
    (TVTuple ts, TupleSel n _)  -> setTuple ts n
    (TVRec fs, RecordSel n _)   -> setRecord fs n
    (TVSeq len a, ListSel ix _) -> setList (Nat len) a (toInteger ix)
    (TVStream a, ListSel ix _)  -> setList Inf a (toInteger ix)
    _ -> bad ("type/selector mismatch")

  where
  bad msg =
      evalPanic "Cryptol.Eval.evalSetSel"
          [ msg
          , "Selector: " ++ show (ppSelector sel)
          , "Type: " ++ show tyv
          ]

  setTuple ts n =
    pure $ VTuple
      [ if i == n then v else
          do vs <- fromVTuple <$> e
             genericIndex vs i
      | (i,_t) <- zip [0 ..] ts
      ]

  setRecord fs n =
    pure $ VRecord $
      mapWithFieldName
        (\f _tp -> if f == n then v else
           do vs <- fromVRecord <$> e
              case lookupField f vs of
                Just val -> val
                Nothing  -> evalPanic "missing field!"
                              [ show f
                              , "Expected: " ++ show (map fst $ canonicalFields fs)
                              , "Got: "++ show (map fst $ canonicalFields vs)
                              ])
        fs

  setList len a n =
    do vs <- delaySeqMap sym (fromVSeq <$> e)
       VSeq len a <$> updateSeqMap sym vs n v

-- List Comprehension Environments ---------------------------------------------

-- | Evaluation environments for list comprehensions: Each variable
-- name is bound to a list of values, one for each element in the list
-- comprehension.
data ListEnv sym = ListEnv
  { leVars   :: !(Map.Map Name (Integer -> SEval sym (GenValue sym)))
      -- ^ Bindings whose values vary by position
  , leStatic :: !(Map.Map Name (SEval sym (GenValue sym)))
      -- ^ Bindings whose values are constant
  , leTypes  :: !TypeEnv
  }

instance Semigroup (ListEnv sym) where
  l <> r = ListEnv
    { leVars   = Map.union (leVars  l)  (leVars  r)
    , leStatic = Map.union (leStatic l) (leStatic r)
    , leTypes  = Map.union (leTypes l)  (leTypes r)
    }

instance Monoid (ListEnv sym) where
  mempty = ListEnv
    { leVars   = Map.empty
    , leStatic = Map.empty
    , leTypes  = Map.empty
    }

  mappend l r = l <> r

toListEnv :: GenEvalEnv sym -> ListEnv sym
toListEnv e =
  ListEnv
  { leVars   = mempty
  , leStatic = envVars e
  , leTypes  = envTypes e
  }
{-# INLINE toListEnv #-}

-- | Evaluate a list environment at a position.
--   This choses a particular value for the varying
--   locations.
evalListEnv :: ListEnv sym -> Integer -> GenEvalEnv sym
evalListEnv (ListEnv vm st tm) i =
    let v = fmap ($i) vm
     in EvalEnv{ envVars = Map.union v st
               , envTypes = tm
               }
{-# INLINE evalListEnv #-}


bindVarList ::
  Name ->
  (Integer -> SEval sym (GenValue sym)) ->
  ListEnv sym ->
  ListEnv sym
bindVarList n vs lenv = lenv { leVars = Map.insert n vs (leVars lenv) }
{-# INLINE bindVarList #-}

-- List Comprehensions ---------------------------------------------------------

{-# SPECIALIZE evalComp ::
  ConcPrims =>
  Concrete ->
  GenEvalEnv Concrete ->
  Nat'           ->
  TValue         ->
  Expr           ->
  [[Match]]      ->
  SEval Concrete (GenValue Concrete)
  #-}
-- | Evaluate a comprehension.
evalComp ::
  EvalPrims sym =>
  sym ->
  GenEvalEnv sym {- ^ Starting evaluation environment -} ->
  Nat'           {- ^ Length of the comprehension -} ->
  TValue         {- ^ Type of the comprehension elements -} ->
  Expr           {- ^ Head expression of the comprehension -} ->
  [[Match]]      {- ^ List of parallel comprehension branches -} ->
  SEval sym (GenValue sym)
evalComp sym env len elty body ms =
       do lenv <- mconcat <$> mapM (branchEnvs sym (toListEnv env)) ms
          VSeq len elty <$>
              (memoMap sym =<< generateSeqMap sym (\i ->
                 evalExpr sym (evalListEnv lenv i) body))

{-# SPECIALIZE branchEnvs ::
  ConcPrims =>
  Concrete ->
  ListEnv Concrete ->
  [Match] ->
  SEval Concrete (ListEnv Concrete)
  #-}
-- | Turn a list of matches into the final environments for each iteration of
-- the branch.
branchEnvs ::
  EvalPrims sym =>
  sym ->
  ListEnv sym ->
  [Match] ->
  SEval sym (ListEnv sym)
branchEnvs sym env matches = foldM (evalMatch sym) env matches

{-# SPECIALIZE evalMatch ::
  ConcPrims =>
  Concrete ->
  ListEnv Concrete ->
  Match ->
  SEval Concrete (ListEnv Concrete)
  #-}

-- | Turn a match into the list of environments it represents.
evalMatch ::
  EvalPrims sym =>
  sym ->
  ListEnv sym ->
  Match ->
  SEval sym (ListEnv sym)
evalMatch sym lenv m = case m of

  -- many envs
  From n l _ty expr ->
    case len of
      -- Select from a sequence of finite length.  This causes us to 'stutter'
      -- through our previous choices `nLen` times.
      Nat nLen -> do
        vss <- memoMap sym =<< generateSeqMap sym
                 (\i -> evalExpr sym (evalListEnv lenv i) expr)
        vs <- joinSeqMap sym nLen vss
        let stutter xs = \i -> xs (i `div` nLen)
        let lenv' = lenv { leVars = fmap stutter (leVars lenv) }
        return $ bindVarList n (\i -> lookupSeqMap sym i vs) lenv'

      -- Select from a sequence of infinite length.  Note that this means we
      -- will never need to backtrack into previous branches.  Thus, we can convert
      -- `leVars` elements of the comprehension environment into `leStatic` elements
      -- by selecting out the 0th element.
      Inf -> do
        let allvars = Map.union (fmap ($0) (leVars lenv)) (leStatic lenv)
        let lenv' = lenv { leVars   = Map.empty
                         , leStatic = allvars
                         }
        let env   = EvalEnv allvars (leTypes lenv)
        xs <- memoMap sym . fromVSeq =<< evalExpr sym env expr
        return $ bindVarList n (\i -> lookupSeqMap sym i xs) lenv'

    where
      len  = evalNumType (leTypes lenv) l

  -- XXX we don't currently evaluate these as though they could be recursive, as
  -- they are typechecked that way; the read environment to evalExpr is the same
  -- as the environment to bind a new name in.
  Let d -> return $ bindVarList (dName d) (\i -> f (evalListEnv lenv i)) lenv
    where
      f env =
          case dDefinition d of
            DPrim   -> evalPanic "evalMatch" ["Unexpected local primitive"]
            DExpr e -> evalExpr sym env e
