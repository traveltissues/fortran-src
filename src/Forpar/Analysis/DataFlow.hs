-- | Dataflow analysis to be applied once basic block analysis is complete.

{-# LANGUAGE FlexibleContexts, PatternGuards, ScopedTypeVariables, TupleSections #-}
module Forpar.Analysis.DataFlow
  ( dominators, iDominators, DomMap, IDomMap
  , postOrder, revPostOrder, OrderF
  , dataFlowSolver, showDataFlow, InOut, InOutMap, InF, OutF
  , liveVariableAnalysis, reachingDefinitions
  , genUDMap, genDUMap, flowsTo, duMapToUdMap, UDMap, DUMap, FlowsGraph
  , blockVarUses, blockVarDefs
  , genBlockMap, genDefMap, BlockMap, DefMap
  , genCallMap, CallMap
  , loopNodes, genBackEdgeMap, BackEdgeMap
  , allVars, allLhsVars
) where

import Data.Generics.Uniplate.Data
import Data.Generics.Uniplate.Operations
import Data.Data
import Data.Function
import Control.Monad.State.Lazy
import Control.Monad.Writer
import Text.PrettyPrint.GenericPretty (pretty, Out)
import Forpar.Analysis
import Forpar.AST
import qualified Data.Map as M
import qualified Data.IntMap as IM
import qualified Data.Set as S
import qualified Data.IntSet as IS
import Data.Graph.Inductive
import Data.Graph.Inductive.PatriciaTree (Gr)
import Data.Graph.Inductive.Query.TransClos
import Data.Maybe
import Data.List (foldl', (\\), union, delete, nub, intersect)

--------------------------------------------------

-- | DomMap : node -> dominators of node
type DomMap = IM.IntMap IS.IntSet

-- | Compute dominators of each bblock in the graph. Node A dominates
-- node B when all paths from the start node (0) must pass through
-- node A in order to reach node B. That will be represented as the
-- relation (B, [A, ...]) in the DomMap.
dominators :: BBGr a -> DomMap
dominators = IM.fromList . map (fmap IS.fromList) . flip dom 0

-- | IDomMap : node -> immediate dominator of node
type IDomMap = IM.IntMap Int

-- | Compute the immediate dominator of each bblock in the graph. The
-- immediate dominator is, in a sense, the 'closest' dominator of a
-- node. Given nodes A and B, you can say that node A is immediately
-- dominated by node B if there does not exist any node C such that:
-- node A dominates node C and node C dominates node B.
iDominators :: BBGr a -> IDomMap
iDominators = IM.fromList . flip iDom 0

-- | An OrderF is a function from graph to a specific ordering of nodes.
type OrderF a = BBGr a -> [Node]

-- | The postordering of a graph outputs the label after traversal of children.
postOrder :: OrderF a
postOrder = postorder . head . dff [0]

-- | Reversed postordering.
revPostOrder :: OrderF a
revPostOrder = reverse . postOrder

-- | The preordering of a graph outputs the label before traversal of children.
preOrder :: OrderF a
preOrder = preorder . head . dff [0]

-- | Reversed preordering.
revPreOrder :: OrderF a
revPreOrder = reverse . preOrder

--------------------------------------------------

-- | Set of names found in an AST node.
allVars :: (Data a, Data (b a)) => b a -> [Name]
allVars b = [ v | ExpValue _ _ (ValArray _ v)    <- uniBi b ] ++
            [ v | ExpValue _ _ (ValVariable _ v) <- uniBi b ]
  where
    uniBi :: (Data a, Data (b a)) => b a -> [Expression a]
    uniBi = universeBi

-- | Set of names found in the parts of an AST that are the target of
-- an assignment statement.
allLhsVars :: (Data a, Data (b a)) => b a -> [Name]
allLhsVars b = [ v | ExpValue _ _ (ValArray _ v)    <- lhsExprs b ] ++
               [ v | ExpValue _ _ (ValVariable _ v) <- lhsExprs b ] ++
               [ v | ExpSubscript _ _ (ExpValue _ _ (ValArray _ v)) _ <- lhsExprs b ]

-- | Set of names used -- not defined -- by an AST-block.
blockVarUses :: Data a => Block a -> [Name]
blockVarUses (BlStatement _ _ _ (StExpressionAssign _ _ lhs rhs))
  | ExpSubscript _ _ _ subs <- lhs = allVars rhs ++ allVars subs
  | otherwise                      = allVars rhs
blockVarUses (BlDo _ _ _ (DoSpecification _ _ (StExpressionAssign _ _ lhs rhs) e1 e2) _)
  | ExpSubscript _ _ _ subs <- lhs = allVars (rhs, e1, e2) ++ allVars subs
  | otherwise                      = allVars (rhs, e1, e2)
blockVarUses (BlStatement _ _ _ (StDeclaration {})) = []
blockVarUses (BlDoWhile _ _ e1 e2 _)   = allVars (e1, e2)
blockVarUses (BlIf _ _ e1 e2 _)        = allVars (e1, e2)
blockVarUses b                         = allVars b

-- | Set of names defined by an AST-block.
blockVarDefs :: Data a => Block a -> [Name]
blockVarDefs (BlStatement _ _ _ st) = allLhsVars st
blockVarDefs (BlDo _ _ _ doSpec _)  = allLhsVars doSpec
blockVarDefs _                      = []

--------------------------------------------------

-- | InOut : (dataflow into the bblock, dataflow out of the bblock)
type InOut t    = (t, t)

-- | InOutMap : node -> (dataflow into node, dataflow out of node)
type InOutMap t = M.Map Node (InOut t)

-- | InF, a function that returns the in-dataflow for a given node
type InF t      = Node -> t

-- | OutF, a function that returns the out-dataflow for a given node
type OutF t     = Node -> t

-- | Apply the iterative dataflow analysis method.
dataFlowSolver :: Ord t => BBGr a            -- ^ basic block graph
                        -> (Node -> InOut t) -- ^ initialisation for in and out dataflows
                        -> OrderF a          -- ^ ordering function
                        -> (OutF t -> InF t) -- ^ compute the in-flow given an out-flow function
                        -> (InF t -> OutF t) -- ^ compute the out-flow given an in-flow function
                        -> InOutMap t        -- ^ final dataflow for each node
dataFlowSolver gr initF order inF outF = converge (==) $ iterate step initM
  where
    ordNodes = order gr
    initM    = M.fromList [ (n, initF n) | n <- ordNodes ]
    step m   = M.fromList [ (n, (inF (snd . get m) n, outF (fst . get m) n)) | n <- ordNodes ]
    get m n  = fromJust $ M.lookup n m

--------------------------------------------------

-- | BlockMap : AST-block label -> AST-block
-- Each AST-block has been given a unique number label during analysis
-- of basic blocks. The purpose of this map is to provide the ability
-- to lookup AST-blocks by label.
type BlockMap a = IM.IntMap (Block (Analysis a))

-- | Build a BlockMap from the AST. This can only be performed after
-- analyseBasicBlocks has operated and labeled all of the AST-blocks
-- with unique numbers.
genBlockMap :: Data a => ProgramFile (Analysis a) -> BlockMap a
genBlockMap pf = IM.fromList [ (i, b) | b <- universeBi pf, let Just i = insLabel (getAnnotation b) ]

-- | DefMap : variable name -> { AST-block label }
type DefMap = M.Map Name IS.IntSet

-- | Build a DefMap from the BlockMap. This allows us to quickly look
-- up the AST-block labels that wrote into the given variable.
genDefMap :: Data a => BlockMap a -> DefMap
genDefMap bm = M.fromListWith IS.union [
                 (y, IS.singleton i) | (i, b) <- IM.toList bm, y <- allLhsVars b
               ]

--------------------------------------------------

-- | Dataflow analysis for live variables given basic block graph.
-- Muchnick, p. 445: A variable is "live" at a particular program
-- point if there is a path to the exit along which its value may be
-- used before it is redefined. It is "dead" if there is no such path.
liveVariableAnalysis :: Data a => BBGr a -> InOutMap (S.Set Name)
liveVariableAnalysis gr = dataFlowSolver gr (const (S.empty, S.empty)) revPreOrder inn out
  where
    inn outF b = (outF b S.\\ kill b) `S.union` gen b
    out innF b = S.unions [ innF s | s <- suc gr b ]
    kill b     = bblockKill (fromJust $ lab gr b)
    gen b      = bblockGen (fromJust $ lab gr b)

-- | Iterate "KILL" set through a single basic block.
bblockKill :: Data a => [Block a] -> S.Set Name
bblockKill = S.fromList . concatMap blockKill

-- | Iterate "GEN" set through a single basic block.
bblockGen :: Data a => [Block a] -> S.Set Name
bblockGen bs = S.fromList . fst . foldl' f ([], []) $ zip (map blockGen bs) (map blockKill bs)
  where
    f (bbgen, bbkill) (gen, kill) = ((gen \\ bbkill) `union` bbgen, kill `union` bbkill)

-- | "KILL" set for a single AST-block.
blockKill :: Data a => Block a -> [Name]
blockKill = blockVarDefs

-- | "GEN" set for a single AST-block.
blockGen :: Data a => Block a -> [Name]
blockGen = blockVarUses

--------------------------------------------------

-- Reaching Definitions
-- forward flow analysis (revPostOrder)

-- GEN b@( definition of anything ) = {b}
-- KILL b@( definition of y ) = DEFS y    -- technically, except b, but it won't matter
-- DEFS y = { all definitions of y }

-- Within a basic block
-- GEN [] = KILL [] = {}
-- GEN [b_1 .. b_{n+1}] = GEN b_{n+1} `union` (GEN [b_1 .. b_n] `difference` KILL b_{n+1})
-- KILL [b_1 .. b_{n+1}] = KILL b_{n+1} `union` (KILL [b_1 .. b_n] `difference` GEN b_{n+1})

-- Between basic blocks
-- REACHin bb = unions [ REACHout bb | bb <- pred bb ]
-- REACHout bb = GEN bb `union` (REACHin bb `difference` KILL bb)

-- | Reaching definitions dataflow analysis. Reaching definitions are
-- the set of variable-defining AST-block labels that may reach a
-- program point. Suppose AST-block with label A defines a variable
-- named v. Label A may reach another program point labeled P if there
-- is at least one program path from label A to label P that does not
-- redefine variable v.
reachingDefinitions :: Data a => DefMap -> BBGr (Analysis a) -> InOutMap IS.IntSet
reachingDefinitions dm gr = dataFlowSolver gr (const (IS.empty, IS.empty)) revPostOrder inn out
  where
    inn outF b = IS.unions [ outF s | s <- pre gr b ]
    out innF b = gen `IS.union` (innF b IS.\\ kill)
      where (gen, kill) = rdBblockGenKill dm (fromJust $ lab gr b)

-- Compute the "GEN" and "KILL" sets for a given basic block.
rdBblockGenKill :: Data a => DefMap -> [Block (Analysis a)] -> (IS.IntSet, IS.IntSet)
rdBblockGenKill dm bs = foldl' f (IS.empty, IS.empty) $ zip (map gen bs) (map kill bs)
  where
    gen b | null (allLhsVars b) = IS.empty
          | otherwise           = IS.singleton . fromJust . insLabel . getAnnotation $ b
    kill = rdDefs dm
    f (bbgen, bbkill) (gen, kill) =
      ((bbgen IS.\\ kill) `IS.union` gen, (bbkill IS.\\ gen) `IS.union` kill)

-- Set of all AST-block labels that also define variables defined by AST-block b
rdDefs :: Data a => DefMap -> Block a -> IS.IntSet
rdDefs dm b = IS.unions [ IS.empty `fromMaybe` M.lookup y dm | y <- allLhsVars b ]

--------------------------------------------------

-- | DUMap : definition -> { use }
type DUMap = IM.IntMap IS.IntSet

-- | def-use map: map AST-block labels of defining AST-blocks to the
-- AST-blocks that may use the definition.
genDUMap :: Data a => BlockMap a -> DefMap -> BBGr (Analysis a) -> InOutMap IS.IntSet -> DUMap
genDUMap bm dm gr rdefs = IM.unionsWith IS.union duMaps
  where
    -- duMaps for each bblock
    duMaps = [ fst (foldl' inBBlock (IM.empty, is) bs) |
               (n, (is, _)) <- M.toList rdefs,
               let Just bs = lab gr n ]
    -- internal analysis within bblock; fold over list of AST-blocks
    inBBlock (duMap, inSet) b = (duMap', inSet')
      where
        Just i = insLabel (getAnnotation b)
        bduMap = IM.fromListWith IS.union [ (i', IS.singleton i) | i' <- IS.toList inSet, overlap i' ]
        -- asks: does AST-block at label i' define anything used by AST-block b?
        overlap i' = not . null . intersect uses $ blockVarDefs b'
          where Just b' = IM.lookup i' bm
        uses   = blockVarUses b
        duMap' = IM.unionWith IS.union duMap bduMap
        gen b | null (allLhsVars b) = IS.empty
              | otherwise           = IS.singleton . fromJust . insLabel . getAnnotation $ b
        kill   = rdDefs dm
        inSet' = (inSet IS.\\ (kill b)) `IS.union` (gen b)

-- | UDMap : use -> { definition }
type UDMap = IM.IntMap IS.IntSet

-- | Invert the DUMap into a UDMap
duMapToUdMap :: DUMap -> UDMap
duMapToUdMap duMap = IM.fromListWith IS.union [
    (use, IS.singleton def) | (def, uses) <- IM.toList duMap, use <- IS.toList uses
  ]

-- | use-def map: map AST-block labels of variable-using AST-blocks to
-- the AST-blocks that define those variables.
genUDMap :: Data a => BlockMap a -> DefMap -> BBGr (Analysis a) -> InOutMap IS.IntSet -> UDMap
genUDMap bm dm gr = duMapToUdMap . genDUMap bm dm gr

--------------------------------------------------

-- | Convert a UD or DU Map into a graph.
mapToGraph :: DynGraph gr => IM.IntMap a -> IM.IntMap IS.IntSet -> gr a ()
mapToGraph bm m = buildGr [
    ([], i, l, jAdj) | (i, js) <- IM.toList m
                     , let Just l = IM.lookup i bm
                     , let jAdj = map ((),) $ IS.toList js
  ]

-- | FlowsGraph : nodes as AST-block (numbered by label), edges
-- showing which definitions contribute to which uses.
type FlowsGraph a = Gr (Block (Analysis a)) ()

-- | "Flows-To" analysis. Compute the transitive closure of a def-use
-- map and represent as a graph.
flowsTo :: Data a => BlockMap a -> DefMap -> BBGr (Analysis a) -> InOutMap IS.IntSet -> FlowsGraph a
flowsTo bm dm gr = trc . mapToGraph bm . genDUMap bm dm gr

--------------------------------------------------

-- | BackEdgeMap : node -> node
type BackEdgeMap = IM.IntMap Node

-- | Find the edges that 'loop back' in the graph; ones where the
-- target node dominates the source node.
genBackEdgeMap :: Graph gr => IM.IntMap IS.IntSet -> gr a b -> BackEdgeMap
genBackEdgeMap domMap = IM.filterWithKey isBackEdge . IM.fromList . edges
  where
    isBackEdge s t = t `IS.member` (fromJust $ s `IM.lookup` domMap)

-- | For each loop in the program, find out which bblock nodes are
-- part of the loop by looking through the backedges (m, n) where n is
-- considered the 'loop-header', delete n from the map, and then do a
-- reverse-depth-first traversal starting from m to find all the nodes
-- of interest. Intersect this with the strongly-connected component
-- containing m, in case of 'improper' graphs with weird control
-- transfers.
loopNodes :: Graph gr => BackEdgeMap -> gr a b -> [IS.IntSet]
loopNodes bedges gr = [
    IS.fromList (n:intersect (sccWith n gr) (rdfs [m] (delNode n gr))) | (m, n) <- IM.toList bedges
  ]

-- | The strongly connected component containing a given node.
sccWith :: (Graph gr) => Node -> gr a b -> [Node]
sccWith n g = case filter (n `elem`) $ scc g of
  []  -> []
  c:_ -> c

--------------------------------------------------

-- | Show some information about dataflow analyses.
showDataFlow :: (Data a, Out a, Show a) => ProgramFile (Analysis a) -> String
showDataFlow pf@(ProgramFile cm_pus _) = (perPU . snd) =<< cm_pus
  where
    perPU pu | Analysis { bBlocks = Just gr } <- getAnnotation pu =
      dashes ++ "\n" ++ p ++ "\n" ++ dashes ++ "\n" ++ dfStr gr ++ "\n\n"
      where p = "| Program Unit " ++ show (getName pu) ++ " |"
            dashes = replicate (length p) '-'
            dfStr gr = (\ (l, x) -> '\n':l ++ ": " ++ x) =<< [
                         ("callMap",      show cm)
                       , ("postOrder",    show (postOrder gr))
                       , ("revPostOrder", show (revPostOrder gr))
                       , ("revPreOrder",  show (revPreOrder gr))
                       , ("dominators",   show (dominators gr))
                       , ("iDominators",  show (iDominators gr))
                       , ("lva",          show (M.toList $ lva gr))
                       , ("rd",           show (M.toList $ rd gr))
                       , ("backEdges",    show bedges)
                       , ("topsort",      show (topsort gr))
                       , ("scc ",         show (scc gr))
                       , ("loopNodes",    show (loopNodes bedges gr))
                       , ("duMap",        show (genDUMap bm dm gr (rd gr)))
                       , ("udMap",        show (genUDMap bm dm gr (rd gr)))
                       , ("flowsTo",      show (edges $ flowsTo bm dm gr (rd gr)))
                       ] where
                           bedges = genBackEdgeMap (dominators gr) gr
    perPU _ = ""
    lva = liveVariableAnalysis
    bm = genBlockMap pf
    dm = genDefMap bm
    rd = reachingDefinitions dm
    cm = genCallMap pf

--------------------------------------------------

-- | CallMap : program unit name -> { name of function or subroutine }
type CallMap = M.Map ProgramUnitName (S.Set Name)

-- | Create a call map showing the structure of the program.
genCallMap :: Data a => ProgramFile a -> CallMap
genCallMap pf = flip execState M.empty $ do
  let (ProgramFile cm_pus _) = pf
  forM_ cm_pus $ \ (_, pu) -> do
    let n = getName pu
    let uS :: Data a => ProgramUnit a -> [Statement a]
        uS = universeBi
    let uE :: Data a => ProgramUnit a -> [Expression a]
        uE = universeBi
    m <- get
    let ns = [ n' | StCall _ _ (ExpValue _ _ (ValSubroutineName n')) _ <- uS pu ] ++
             [ n' | ExpFunctionCall _ _ (ExpValue _ _ (ValFunctionName n')) _ <- uE pu ]
    put $ M.insert n (S.fromList ns) m

--------------------------------------------------

-- helper: iterate until predicate is satisfied.
converge :: (a -> a -> Bool) -> [a] -> a
converge p (x:ys@(y:_))
  | p x y     = y
  | otherwise = converge p ys