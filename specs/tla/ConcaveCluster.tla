---------------------------- MODULE ConcaveCluster ----------------------------
(***************************************************************************)
(* Formal TLA+ Specification of a Multi-Replica Concave Cluster            *)
(*                                                                         *)
(* Models the end-to-end architecture implemented in:                      *)
(*   - zig/runtime/engine.zig            (ConcaveEngine, OCC retries,      *)
(*                                        commit_log tailer, invalidation) *)
(*   - zig/core/wal_store.zig            (ACID commitTx, OCC ReadSet/WS)   *)
(*   - client/concave-client/src/client.js (WebSocket client, atomic       *)
(*                                        transition batching, optimistic  *)
(*                                        queue pruning, reconnect)        *)
(*                                                                         *)
(* Components modeled:                                                     *)
(*   1. Shared ACID database + strictly monotonic append-only commit_log   *)
(*   2. N stateless Concave replicas (Cloud Run instances), each tracking  *)
(*      `lastBroadcastTs` and running a background `commit_log` tailer     *)
(*   3. Optimistic Concurrency Control (OCC) mutations:                    *)
(*      BeginTx -> Read -> CommitOrAbort (conflict detection vs commitLog) *)
(*   4. Client WebSocket lifecycle:                                        *)
(*      Subscribe, Unsubscribe, OptimisticMutate, out-of-order Transition  *)
(*      & MutationResult delivery, and Disconnect / Reconnect across       *)
(*      arbitrary replicas                                                 *)
(*                                                                         *)
(* Run TLC model checking from specs/tla/:                                 *)
(*   java -jar tla2tools.jar -config ConcaveCluster.cfg ConcaveCluster.tla *)
(*                                                                         *)
(* Or with parallel workers:                                               *)
(*   java -XX:+UseParallelGC -jar tla2tools.jar -workers auto \            *)
(*        -config ConcaveCluster.cfg ConcaveCluster.tla                    *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Replicas,       \* Set of stateless Concave Cloud Run instances (e.g. {r1, r2})
    Clients,        \* Set of WebSocket clients (e.g. {c1, c2})
    Keys,           \* Set of document keys in the shared database (e.g. {k1, k2})
    Values,         \* Finite domain of document values (e.g. {0, 1})
    TxIds,          \* Finite pool of concurrent OCC transaction slots (e.g. {t1, t2})
    MaxCommitTs,    \* Bounded commit_log length for TLC exploration (e.g. 2)
    MaxReqs,        \* Maximum mutation requests per client (e.g. 1)
    MaxEpoch        \* Maximum disconnect/reconnect epochs per client (e.g. 1)

ASSUME
    /\ Replicas # {}
    /\ Clients # {}
    /\ Keys # {}
    /\ Values # {}
    /\ TxIds # {}
    /\ MaxCommitTs \in Nat /\ MaxCommitTs >= 1
    /\ MaxReqs \in Nat /\ MaxReqs >= 1
    /\ MaxEpoch \in Nat

-----------------------------------------------------------------------------
(* Constants & Helpers *)

NoReplica == "NO_REPLICA"
NoClient  == "NO_CLIENT"
NoVal     == "NO_VAL"
NoTs      == -1

InitVal == CHOOSE v \in Values : TRUE
AnyKey  == CHOOSE k \in Keys   : TRUE

\* Each query is identified by the non-empty ReadSet of keys it reads
\* (covers both point-document reads {k} and multi-doc / index range scans).
Queries == (SUBSET Keys) \ {{}}

EmptyQueryVal == [k \in Keys |-> NoVal]
EmptyReadVals == [k \in Keys |-> NoVal]
NoSub         == [sinceTs |-> NoTs, lastSentTs |-> NoTs]

Max2(a, b) == IF a >= b THEN a ELSE b
MaxSet(S)  == CHOOSE x \in S : \A y \in S : x >= y

\* Deterministic query evaluation on a database snapshot `snap`.
QueryEval(q, snap) ==
    [k \in Keys |-> IF k \in q THEN snap[k] ELSE NoVal]

IdleTx == [
    status      |-> "idle",
    replica     |-> NoReplica,
    client      |-> NoClient,
    epoch       |-> 0,
    reqId       |-> 0,
    snapTs      |-> 0,
    readSet     |-> {},
    readVals    |-> EmptyReadVals,
    targetKey   |-> AnyKey,
    newVal      |-> InitVal,
    committedTs |-> 0
]

-----------------------------------------------------------------------------
(* State Variables *)

VARIABLES
    \* Shared ACID database & append-only commit_log
    db,                 \* [Keys -> Values]: latest committed DB state
    commitTs,           \* 0..MaxCommitTs: monotonic latest commit timestamp
    dbHistory,          \* [0..MaxCommitTs -> [Keys -> Values]]: snapshot at each ts
    commitLog,          \* Seq([ts, writeSet, originClient]): committed write-sets
    txHistory,          \* Seq([snapTs, committedTs, readSet, readVals, targetKey, newVal])

    \* Stateless Concave replicas (Cloud Run instances)
    lastBroadcastTs,    \* [Replicas -> 0..MaxCommitTs]: commit_log tail cursor
    replicaSubs,        \* [Replicas -> [Clients -> [Queries -> [sinceTs, lastSentTs]]]]

    \* In-flight OCC transactions
    txs,                \* [TxIds -> TxRecord]

    \* WebSocket clients & asynchronous out-of-order network channels
    clientConn,         \* [Clients -> Replicas \cup {NoReplica}]
    clientEpoch,        \* [Clients -> 0..MaxEpoch]: monotonic WS connection generation
    clientCommitTs,     \* [Clients -> 0..MaxCommitTs]: client signal commitTs
    clientPrevCommitTs, \* [Clients -> 0..MaxCommitTs]: previous commitTs (monotonicity)
    clientSubs,         \* [Clients -> SUBSET Queries]: active client subscriptions
    clientSubTs,        \* [Clients -> [Queries -> (0..MaxCommitTs) \cup {NoTs}]]
    clientSubData,      \* [Clients -> [Queries -> [Keys -> Values \cup {NoVal}]]]
    clientNextReq,      \* [Clients -> 1..(MaxReqs + 1)]
    clientOptQueue,     \* [Clients -> Seq([reqId, key, val, resolvedTs])]
    pendingClientMuts,  \* [Clients -> SUBSET [epoch, reqId, key, val]]
    netToClient         \* [Clients -> SUBSET Frame] (unordered: Transition & MutationResult)

dbVars      == <<db, commitTs, dbHistory, commitLog, txHistory>>
replicaVars == <<lastBroadcastTs, replicaSubs>>
txVars      == <<txs>>
clientVars  == <<clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                 clientSubs, clientSubTs, clientSubData,
                 clientNextReq, clientOptQueue, pendingClientMuts, netToClient>>
vars        == <<dbVars, replicaVars, txVars, clientVars>>

-----------------------------------------------------------------------------
(* Derived Helpers *)

ActiveReplicaSubs(r, c) ==
    {q \in Queries : replicaSubs[r][c][q] # NoSub}

\* Reactive signal view computed by `_recomputeOptimisticSignals()` in client.js:
\* overlays `clientOptQueue[c]` in FIFO order on top of `clientSubData[c][q]`.
ClientVisibleView(c, q) ==
    [k \in Keys |->
        IF k \notin q THEN NoVal
        ELSE LET idxs == {i \in 1..Len(clientOptQueue[c]) : clientOptQueue[c][i].key = k}
             IN IF idxs = {} THEN clientSubData[c][q][k]
                ELSE clientOptQueue[c][MaxSet(idxs)].val]

\* OCC conflict check matching zig/core/wal_store.zig commitTx lines 204-212:
\* conflict iff any commit strictly after snapTs wrote a key in tx.readSet.
HasOccConflict(tx) ==
    \E i \in 1..commitTs :
        /\ i > tx.snapTs
        /\ (tx.readSet \cap commitLog[i].writeSet) # {}

-----------------------------------------------------------------------------
(* Type Invariant *)

IsSnapshot(s) ==
    /\ DOMAIN s = Keys
    /\ \A k \in Keys : s[k] \in Values

IsQueryVal(v) ==
    /\ DOMAIN v = Keys
    /\ \A k \in Keys : v[k] \in Values \cup {NoVal}

IsTransitionFrame(f) ==
    /\ DOMAIN f = {"type", "epoch", "toTs", "subs", "updates"}
    /\ f.type = "transition"
    /\ f.epoch \in 0..MaxEpoch
    /\ f.toTs \in 0..MaxCommitTs
    /\ f.subs \subseteq Queries
    /\ DOMAIN f.updates = f.subs
    /\ \A q \in f.subs : IsQueryVal(f.updates[q])

IsMutationResultFrame(f) ==
    /\ DOMAIN f = {"type", "epoch", "reqId", "ok", "commitTs"}
    /\ f.type = "mutation_result"
    /\ f.epoch \in 0..MaxEpoch
    /\ f.reqId \in 1..MaxReqs
    /\ f.ok \in BOOLEAN
    /\ f.commitTs \in 0..MaxCommitTs

IsFrame(f) ==
    IsTransitionFrame(f) \/ IsMutationResultFrame(f)

TypeOK ==
    /\ IsSnapshot(db)
    /\ commitTs \in 0..MaxCommitTs
    /\ DOMAIN dbHistory = 0..MaxCommitTs
    /\ \A ts \in 0..MaxCommitTs : IsSnapshot(dbHistory[ts])
    /\ Len(commitLog) = commitTs
    /\ \A i \in 1..Len(commitLog) :
           /\ commitLog[i].ts = i
           /\ commitLog[i].writeSet \subseteq Keys
           /\ commitLog[i].originClient \in Clients \cup {NoClient}
    /\ Len(txHistory) = commitTs
    /\ \A i \in 1..Len(txHistory) :
           /\ txHistory[i].snapTs \in 0..MaxCommitTs
           /\ txHistory[i].committedTs = i
           /\ txHistory[i].readSet \subseteq Keys
           /\ IsQueryVal(txHistory[i].readVals)
           /\ txHistory[i].targetKey \in Keys
           /\ txHistory[i].newVal \in Values
    /\ lastBroadcastTs \in [Replicas -> 0..MaxCommitTs]
    /\ \A r \in Replicas : lastBroadcastTs[r] <= commitTs
    /\ DOMAIN replicaSubs = Replicas
    /\ \A r \in Replicas :
           /\ DOMAIN replicaSubs[r] = Clients
           /\ \A c \in Clients :
                  /\ DOMAIN replicaSubs[r][c] = Queries
                  /\ \A q \in Queries :
                         /\ replicaSubs[r][c][q].sinceTs \in (0..MaxCommitTs) \cup {NoTs}
                         /\ replicaSubs[r][c][q].lastSentTs \in (0..MaxCommitTs) \cup {NoTs}
    /\ DOMAIN txs = TxIds
    /\ \A t \in TxIds :
           /\ txs[t].status \in {"idle", "active"}
           /\ txs[t].replica \in Replicas \cup {NoReplica}
           /\ txs[t].client \in Clients \cup {NoClient}
           /\ txs[t].epoch \in 0..MaxEpoch
           /\ txs[t].reqId \in 0..MaxReqs
           /\ txs[t].snapTs \in 0..MaxCommitTs
           /\ txs[t].readSet \subseteq Keys
           /\ IsQueryVal(txs[t].readVals)
           /\ txs[t].targetKey \in Keys
           /\ txs[t].newVal \in Values
           /\ txs[t].committedTs \in 0..MaxCommitTs
    /\ clientConn \in [Clients -> Replicas \cup {NoReplica}]
    /\ clientEpoch \in [Clients -> 0..MaxEpoch]
    /\ clientCommitTs \in [Clients -> 0..MaxCommitTs]
    /\ clientPrevCommitTs \in [Clients -> 0..MaxCommitTs]
    /\ clientSubs \in [Clients -> SUBSET Queries]
    /\ DOMAIN clientSubTs = Clients
    /\ \A c \in Clients :
           /\ DOMAIN clientSubTs[c] = Queries
           /\ \A q \in Queries : clientSubTs[c][q] \in (0..MaxCommitTs) \cup {NoTs}
    /\ DOMAIN clientSubData = Clients
    /\ \A c \in Clients :
           /\ DOMAIN clientSubData[c] = Queries
           /\ \A q \in Queries : IsQueryVal(clientSubData[c][q])
    /\ clientNextReq \in [Clients -> 1..(MaxReqs + 1)]
    /\ DOMAIN clientOptQueue = Clients
    /\ \A c \in Clients :
           \A i \in 1..Len(clientOptQueue[c]) :
               /\ clientOptQueue[c][i].reqId \in 1..MaxReqs
               /\ clientOptQueue[c][i].key \in Keys
               /\ clientOptQueue[c][i].val \in Values
               /\ clientOptQueue[c][i].resolvedTs \in (0..MaxCommitTs) \cup {NoTs}
    /\ DOMAIN pendingClientMuts = Clients
    /\ \A c \in Clients :
           \A req \in pendingClientMuts[c] :
               /\ req.epoch \in 0..MaxEpoch
               /\ req.reqId \in 1..MaxReqs
               /\ req.key \in Keys
               /\ req.val \in Values
    /\ DOMAIN netToClient = Clients
    /\ \A c \in Clients : \A f \in netToClient[c] : IsFrame(f)

-----------------------------------------------------------------------------
(* Initial State *)

Init ==
    /\ db                 = [k \in Keys |-> InitVal]
    /\ commitTs           = 0
    /\ dbHistory          = [ts \in 0..MaxCommitTs |-> [k \in Keys |-> InitVal]]
    /\ commitLog          = <<>>
    /\ txHistory          = <<>>
    /\ lastBroadcastTs    = [r \in Replicas |-> 0]
    /\ replicaSubs        = [r \in Replicas |-> [c \in Clients |-> [q \in Queries |-> NoSub]]]
    /\ txs                = [t \in TxIds |-> IdleTx]
    /\ clientConn         = [c \in Clients |-> NoReplica]
    /\ clientEpoch        = [c \in Clients |-> 0]
    /\ clientCommitTs     = [c \in Clients |-> 0]
    /\ clientPrevCommitTs = [c \in Clients |-> 0]
    /\ clientSubs         = [c \in Clients |-> {}]
    /\ clientSubTs        = [c \in Clients |-> [q \in Queries |-> NoTs]]
    /\ clientSubData      = [c \in Clients |-> [q \in Queries |-> EmptyQueryVal]]
    /\ clientNextReq      = [c \in Clients |-> 1]
    /\ clientOptQueue     = [c \in Clients |-> <<>>]
    /\ pendingClientMuts  = [c \in Clients |-> {}]
    /\ netToClient        = [c \in Clients |-> {}]

-----------------------------------------------------------------------------
(* Actions: OCC Mutations on Stateless Replicas *)

\* Start an HTTP / background OCC mutation on replica `r` at snapshot `commitTs`.
BeginTx(t, r, k, v) ==
    /\ txs[t].status = "idle"
    /\ commitTs < MaxCommitTs
    /\ txs' = [txs EXCEPT ![t] = [
           status      |-> "active",
           replica     |-> r,
           client      |-> NoClient,
           epoch       |-> 0,
           reqId       |-> 0,
           snapTs      |-> commitTs,
           readSet     |-> {},
           readVals    |-> EmptyReadVals,
           targetKey   |-> k,
           newVal      |-> v,
           committedTs |-> 0
       ]]
    /\ UNCHANGED <<dbVars, replicaVars, clientVars>>

\* Replica `r` begins an OCC transaction for a queued client WebSocket mutation.
BeginClientTx(t, r, c, req) ==
    /\ txs[t].status = "idle"
    /\ clientConn[c] = r
    /\ req \in pendingClientMuts[c]
    /\ req.epoch = clientEpoch[c]
    /\ txs' = [txs EXCEPT ![t] = [
           status      |-> "active",
           replica     |-> r,
           client      |-> c,
           epoch       |-> req.epoch,
           reqId       |-> req.reqId,
           snapTs      |-> commitTs,
           readSet     |-> {},
           readVals    |-> EmptyReadVals,
           targetKey   |-> req.key,
           newVal      |-> req.val,
           committedTs |-> 0
       ]]
    /\ pendingClientMuts' = [pendingClientMuts EXCEPT ![c] = @ \ {req}]
    /\ UNCHANGED <<dbVars, replicaVars,
                   clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                   clientSubs, clientSubTs, clientSubData,
                   clientNextReq, clientOptQueue, netToClient>>

\* Read key `k` from transaction `t`'s snapshot `dbHistory[snapTs]` and record in ReadSet.
TxRead(t, k) ==
    /\ txs[t].status = "active"
    /\ k \notin txs[t].readSet
    /\ txs' = [txs EXCEPT ![t].readSet     = @ \cup {k},
                          ![t].readVals[k] = dbHistory[txs[t].snapTs][k]]
    /\ UNCHANGED <<dbVars, replicaVars, clientVars>>

\* Validate OCC ReadSet against all commits strictly after `snapTs`, then atomically
\* commit (appending to commitLog) or abort (sending error MutationResult to client).
CommitOrAbort(t) ==
    /\ txs[t].status = "active"
    /\ txs[t].readSet # {}
    /\ LET tx       == txs[t]
           conflict == HasOccConflict(tx)
       IN IF conflict \/ commitTs = MaxCommitTs THEN
              \* OCC conflict (or bounded horizon): abort transaction, no DB change.
              /\ txs' = [txs EXCEPT ![t] = IdleTx]
              /\ IF tx.client # NoClient THEN
                     LET resFrame == [
                             type     |-> "mutation_result",
                             epoch    |-> tx.epoch,
                             reqId    |-> tx.reqId,
                             ok       |-> FALSE,
                             commitTs |-> 0
                         ]
                     IN netToClient' = [netToClient EXCEPT ![tx.client] = @ \cup {resFrame}]
                 ELSE
                     UNCHANGED netToClient
              /\ UNCHANGED <<dbVars, replicaVars,
                             clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                             clientSubs, clientSubTs, clientSubData,
                             clientNextReq, clientOptQueue, pendingClientMuts>>
          ELSE
              \* OCC validation passed: atomic commit at `newTs = commitTs + 1`.
              LET newTs == commitTs + 1
                  newDb == [db EXCEPT ![tx.targetKey] = tx.newVal]
                  logEntry == [
                      ts           |-> newTs,
                      writeSet     |-> {tx.targetKey},
                      originClient |-> tx.client
                  ]
                  histEntry == [
                      snapTs      |-> tx.snapTs,
                      committedTs |-> newTs,
                      readSet     |-> tx.readSet,
                      readVals    |-> tx.readVals,
                      targetKey   |-> tx.targetKey,
                      newVal      |-> tx.newVal
                  ]
              IN /\ db'        = newDb
                 /\ commitTs'  = newTs
                 /\ dbHistory' = [dbHistory EXCEPT ![newTs] = newDb]
                 /\ commitLog' = Append(commitLog, logEntry)
                 /\ txHistory' = Append(txHistory, histEntry)
                 /\ txs'       = [txs EXCEPT ![t] = IdleTx]
                 /\ IF tx.client # NoClient THEN
                        LET resFrame == [
                                type     |-> "mutation_result",
                                epoch    |-> tx.epoch,
                                reqId    |-> tx.reqId,
                                ok       |-> TRUE,
                                commitTs |-> newTs
                            ]
                        IN netToClient' = [netToClient EXCEPT ![tx.client] = @ \cup {resFrame}]
                    ELSE
                        UNCHANGED netToClient
                 /\ UNCHANGED <<replicaVars,
                                clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                                clientSubs, clientSubTs, clientSubData,
                                clientNextReq, clientOptQueue, pendingClientMuts>>

-----------------------------------------------------------------------------
(* Actions: Stateless Replica commit_log Tailer & Atomic Transition Broadcast *)

\* Replica `r` advances `lastBroadcastTs[r]` by one commit entry (models both
\* `handleLocalCommit` and background `pollCommitLog` in zig/runtime/engine.zig),
\* broadcasting ONE atomic Transition frame per impacted connected client.
ReplicaTailCommitLog(r) ==
    /\ lastBroadcastTs[r] < commitTs
    /\ LET nextTs == lastBroadcastTs[r] + 1
           entry  == commitLog[nextTs]
           Impacted(c) ==
               IF clientConn[c] = r THEN
                   {q \in ActiveReplicaSubs(r, c) :
                       /\ replicaSubs[r][c][q].sinceTs < nextTs
                       /\ (q \cap entry.writeSet) # {}}
               ELSE {}
           ShouldNotify(c) ==
               /\ clientConn[c] = r
               /\ (Impacted(c) # {} \/ entry.originClient = c)
           FrameFor(c) == [
               type    |-> "transition",
               epoch   |-> clientEpoch[c],
               toTs    |-> nextTs,
               subs    |-> Impacted(c),
               updates |-> [q \in Impacted(c) |-> QueryEval(q, dbHistory[nextTs])]
           ]
       IN /\ lastBroadcastTs' = [lastBroadcastTs EXCEPT ![r] = nextTs]
          /\ replicaSubs' = [replicaSubs EXCEPT ![r] =
                 [c \in Clients |->
                     [q \in Queries |->
                         IF q \in Impacted(c)
                         THEN [replicaSubs[r][c][q] EXCEPT !.lastSentTs = nextTs]
                         ELSE replicaSubs[r][c][q]]]]
          /\ netToClient' = [c \in Clients |->
                 IF ShouldNotify(c)
                 THEN netToClient[c] \cup {FrameFor(c)}
                 ELSE netToClient[c]]
          /\ UNCHANGED <<dbVars, txVars,
                         clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                         clientSubs, clientSubTs, clientSubData,
                         clientNextReq, clientOptQueue, pendingClientMuts>>

-----------------------------------------------------------------------------
(* Actions: Client WebSocket Protocol *)

\* Client subscribes to query `q` (if connected, replica evaluates at `commitTs`
\* and emits an initial Transition frame; if disconnected, queued for reconnect).
ClientSubscribe(c, q) ==
    /\ q \in Queries
    /\ q \notin clientSubs[c]
    /\ clientSubs' = [clientSubs EXCEPT ![c] = @ \cup {q}]
    /\ IF clientConn[c] # NoReplica THEN
           LET r == clientConn[c]
               initFrame == [
                   type    |-> "transition",
                   epoch   |-> clientEpoch[c],
                   toTs    |-> commitTs,
                   subs    |-> {q},
                   updates |-> [x \in {q} |-> QueryEval(x, dbHistory[commitTs])]
               ]
           IN /\ replicaSubs' = [replicaSubs EXCEPT ![r][c][q] =
                     [sinceTs |-> commitTs, lastSentTs |-> commitTs]]
              /\ netToClient' = [netToClient EXCEPT ![c] = @ \cup {initFrame}]
       ELSE
           UNCHANGED <<replicaSubs, netToClient>>
    /\ UNCHANGED <<dbVars, lastBroadcastTs, txVars,
                   clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                   clientSubTs, clientSubData, clientNextReq, clientOptQueue,
                   pendingClientMuts>>

\* Client unsubscribes from query `q`, releasing server subscription state.
ClientUnsubscribe(c, q) ==
    /\ q \in clientSubs[c]
    /\ clientSubs'    = [clientSubs    EXCEPT ![c] = @ \ {q}]
    /\ clientSubTs'   = [clientSubTs   EXCEPT ![c][q] = NoTs]
    /\ clientSubData' = [clientSubData EXCEPT ![c][q] = EmptyQueryVal]
    /\ IF clientConn[c] # NoReplica THEN
           replicaSubs' = [replicaSubs EXCEPT ![clientConn[c]][c][q] = NoSub]
       ELSE
           UNCHANGED replicaSubs
    /\ UNCHANGED <<dbVars, lastBroadcastTs, txVars,
                   clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                   clientNextReq, clientOptQueue, pendingClientMuts, netToClient>>

\* Client issues an optimistic mutation (models `client.mutate(..., { optimisticUpdate })`):
\* appends optimistic overlay immediately and dispatches mutation request to its replica.
ClientOptimisticMutate(c, k, v) ==
    /\ clientConn[c] # NoReplica
    /\ clientNextReq[c] <= MaxReqs
    /\ commitTs < MaxCommitTs
    /\ LET reqId == clientNextReq[c]
           opt   == [reqId |-> reqId, key |-> k, val |-> v, resolvedTs |-> NoTs]
           req   == [epoch |-> clientEpoch[c], reqId |-> reqId, key |-> k, val |-> v]
       IN /\ clientNextReq'     = [clientNextReq     EXCEPT ![c] = reqId + 1]
          /\ clientOptQueue'    = [clientOptQueue    EXCEPT ![c] = Append(@, opt)]
          /\ pendingClientMuts' = [pendingClientMuts EXCEPT ![c] = @ \cup {req}]
    /\ UNCHANGED <<dbVars, replicaVars, txVars,
                   clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                   clientSubs, clientSubTs, clientSubData, netToClient>>

\* Client receives an (arbitrarily reordered) Transition frame and atomically
\* updates commitTs, ready subscription snapshots, and optimistic queue pruning.
ClientRecvTransition(c, f) ==
    /\ f \in netToClient[c]
    /\ f.type = "transition"
    /\ IF f.epoch # clientEpoch[c] THEN
           \* Drop stale frame from closed WebSocket (`if (this._ws !== ws) return;`).
           /\ netToClient' = [netToClient EXCEPT ![c] = @ \ {f}]
           /\ UNCHANGED <<dbVars, replicaVars, txVars,
                          clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                          clientSubs, clientSubTs, clientSubData,
                          clientNextReq, clientOptQueue, pendingClientMuts>>
       ELSE
           LET newTs == Max2(clientCommitTs[c], f.toTs)
               ShouldApply(q) ==
                   /\ q \in f.subs
                   /\ q \in clientSubs[c]
                   /\ (clientSubTs[c][q] = NoTs \/ f.toTs >= clientSubTs[c][q])
               KeepOpt(o) ==
                   o.resolvedTs = NoTs \/ newTs < o.resolvedTs
           IN /\ clientPrevCommitTs' = [clientPrevCommitTs EXCEPT ![c] = clientCommitTs[c]]
              /\ clientCommitTs'     = [clientCommitTs     EXCEPT ![c] = newTs]
              /\ clientSubTs' = [clientSubTs EXCEPT ![c] =
                     [q \in Queries |->
                         IF ShouldApply(q) THEN f.toTs ELSE clientSubTs[c][q]]]
              /\ clientSubData' = [clientSubData EXCEPT ![c] =
                     [q \in Queries |->
                         IF ShouldApply(q) THEN f.updates[q] ELSE clientSubData[c][q]]]
              /\ clientOptQueue' = [clientOptQueue EXCEPT ![c] =
                     SelectSeq(clientOptQueue[c], KeepOpt)]
              /\ netToClient' = [netToClient EXCEPT ![c] = @ \ {f}]
              /\ UNCHANGED <<dbVars, replicaVars, txVars,
                             clientConn, clientEpoch, clientSubs,
                             clientNextReq, pendingClientMuts>>

\* Client receives an (arbitrarily reordered) MutationResult frame:
\*   - ok = TRUE:  stamps `resolvedTs = f.commitTs`, prunes immediately if
\*                 `clientCommitTs[c] >= f.commitTs` (handles Transition-before-Result).
\*   - ok = FALSE: rolls back the optimistic entry immediately.
ClientRecvMutationResult(c, f) ==
    /\ f \in netToClient[c]
    /\ f.type = "mutation_result"
    /\ IF f.epoch # clientEpoch[c] THEN
           /\ netToClient' = [netToClient EXCEPT ![c] = @ \ {f}]
           /\ UNCHANGED <<dbVars, replicaVars, txVars,
                          clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                          clientSubs, clientSubTs, clientSubData,
                          clientNextReq, clientOptQueue, pendingClientMuts>>
       ELSE
           /\ IF f.ok THEN
                  LET updated ==
                          [i \in 1..Len(clientOptQueue[c]) |->
                              IF clientOptQueue[c][i].reqId = f.reqId
                              THEN [clientOptQueue[c][i] EXCEPT !.resolvedTs = f.commitTs]
                              ELSE clientOptQueue[c][i]]
                      KeepOpt(o) ==
                          o.resolvedTs = NoTs \/ clientCommitTs[c] < o.resolvedTs
                  IN clientOptQueue' = [clientOptQueue EXCEPT ![c] =
                         SelectSeq(updated, KeepOpt)]
              ELSE
                  LET KeepOpt(o) == o.reqId # f.reqId
                  IN clientOptQueue' = [clientOptQueue EXCEPT ![c] =
                         SelectSeq(clientOptQueue[c], KeepOpt)]
           /\ netToClient' = [netToClient EXCEPT ![c] = @ \ {f}]
           /\ UNCHANGED <<dbVars, replicaVars, txVars,
                          clientConn, clientEpoch, clientCommitTs, clientPrevCommitTs,
                          clientSubs, clientSubTs, clientSubData,
                          clientNextReq, pendingClientMuts>>

\* Client WebSocket drops: server unregisters session, client bumps epoch and rolls back
\* unresolved in-flight optimistic mutations whose RPCs were lost on the broken socket.
ClientDisconnect(c) ==
    /\ clientConn[c] # NoReplica
    /\ clientEpoch[c] < MaxEpoch
    /\ LET oldR == clientConn[c]
           KeepResolved(o) == o.resolvedTs # NoTs
       IN /\ clientConn'        = [clientConn        EXCEPT ![c] = NoReplica]
          /\ clientEpoch'       = [clientEpoch       EXCEPT ![c] = @ + 1]
          /\ replicaSubs'       = [replicaSubs       EXCEPT ![oldR][c] = [q \in Queries |-> NoSub]]
          /\ pendingClientMuts' = [pendingClientMuts EXCEPT ![c] = {}]
          /\ clientOptQueue'    = [clientOptQueue    EXCEPT ![c] =
                 SelectSeq(clientOptQueue[c], KeepResolved)]
    /\ UNCHANGED <<dbVars, lastBroadcastTs, txVars,
                   clientCommitTs, clientPrevCommitTs,
                   clientSubs, clientSubTs, clientSubData,
                   clientNextReq, netToClient>>

\* Client connects (or reconnects after drop) to any stateless replica `r`:
\* re-subscribes all active queries and receives an atomic snapshot Transition at `commitTs`.
ClientReconnect(c, r) ==
    /\ clientConn[c] = NoReplica
    /\ r \in Replicas
    /\ LET syncFrame == [
               type    |-> "transition",
               epoch   |-> clientEpoch[c],
               toTs    |-> commitTs,
               subs    |-> clientSubs[c],
               updates |-> [q \in clientSubs[c] |-> QueryEval(q, dbHistory[commitTs])]
           ]
       IN /\ clientConn'  = [clientConn  EXCEPT ![c] = r]
          /\ replicaSubs' = [replicaSubs EXCEPT ![r][c] =
                 [q \in Queries |->
                     IF q \in clientSubs[c]
                     THEN [sinceTs |-> commitTs, lastSentTs |-> commitTs]
                     ELSE NoSub]]
          /\ netToClient' = [netToClient EXCEPT ![c] = @ \cup {syncFrame}]
    /\ UNCHANGED <<dbVars, lastBroadcastTs, txVars,
                   clientEpoch, clientCommitTs, clientPrevCommitTs,
                   clientSubs, clientSubTs, clientSubData,
                   clientNextReq, clientOptQueue, pendingClientMuts>>

-----------------------------------------------------------------------------
(* Next-State Relation & Fairness *)

ClientDeliverStep(c) ==
    \E f \in netToClient[c] :
        ClientRecvTransition(c, f) \/ ClientRecvMutationResult(c, f)

ReplicaStartClientTxStep(r) ==
    \E t \in TxIds, c \in Clients :
        \E req \in pendingClientMuts[c] :
            BeginClientTx(t, r, c, req)

TxProgressStep(t) ==
    \/ (\E k \in Keys : TxRead(t, k))
    \/ CommitOrAbort(t)

ClientConnectStep(c) ==
    \E r \in Replicas : ClientReconnect(c, r)

Next ==
    \/ \E t \in TxIds, r \in Replicas, k \in Keys, v \in Values : BeginTx(t, r, k, v)
    \/ \E r \in Replicas : ReplicaStartClientTxStep(r)
    \/ \E t \in TxIds : TxProgressStep(t)
    \/ \E r \in Replicas : ReplicaTailCommitLog(r)
    \/ \E c \in Clients, q \in Queries : ClientSubscribe(c, q)
    \/ \E c \in Clients, q \in Queries : ClientUnsubscribe(c, q)
    \/ \E c \in Clients, k \in Keys, v \in Values : ClientOptimisticMutate(c, k, v)
    \/ \E c \in Clients : ClientDeliverStep(c)
    \/ \E c \in Clients : ClientDisconnect(c)
    \/ \E c \in Clients : ClientConnectStep(c)

\* Weak fairness on background tailing, in-flight tx completion, frame delivery,
\* and client reconnection (client disconnects and new mutations remain non-fair).
Fairness ==
    /\ \A r \in Replicas : WF_vars(ReplicaTailCommitLog(r))
    /\ \A r \in Replicas : WF_vars(ReplicaStartClientTxStep(r))
    /\ \A t \in TxIds    : WF_vars(TxProgressStep(t))
    /\ \A t \in TxIds    : WF_vars(CommitOrAbort(t))
    /\ \A c \in Clients  : WF_vars(ClientDeliverStep(c))
    /\ \A c \in Clients  : WF_vars(ClientConnectStep(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Safety Invariants *)

\* 1. Strict Serializability:
\*    Every committed transaction's reads match the exact DB state immediately
\*    preceding its atomic serialization point (`committedTs - 1`), its write
\*    produces `dbHistory[committedTs]`, and real-time order is preserved.
StrictSerializability ==
    /\ Len(txHistory) = commitTs
    /\ db = dbHistory[commitTs]
    /\ \A i \in 1..Len(txHistory) :
           LET rec == txHistory[i] IN
           /\ rec.committedTs = i
           /\ rec.snapTs < rec.committedTs
           /\ \A k \in rec.readSet :
                  rec.readVals[k] = dbHistory[i - 1][k]
           /\ dbHistory[i] = [dbHistory[i - 1] EXCEPT ![rec.targetKey] = rec.newVal]
           /\ \A j \in 1..Len(txHistory) :
                  txHistory[j].committedTs <= rec.snapTs => j < i

\* 2. No Missed Invalidation:
\*    Once replica `r` has advanced `lastBroadcastTs[r]` past a commit `ts`,
\*    every active subscription on `r` that existed before `ts` and intersects
\*    `commitLog[ts].writeSet` has already been invalidated at some `toTs >= ts`.
NoMissedInvalidation ==
    \A r \in Replicas :
        \A c \in Clients :
            \A q \in ActiveReplicaSubs(r, c) :
                \A ts \in 1..lastBroadcastTs[r] :
                    (ts > replicaSubs[r][c][q].sinceTs /\ (q \cap commitLog[ts].writeSet) # {})
                        => replicaSubs[r][c][q].lastSentTs >= ts

\* 3. Monotonic Client Commit Timestamp:
\*    `clientCommitTs[c]` never regresses (even under out-of-order frames or
\*    failover across replicas) and never exceeds the database's `commitTs`.
MonotonicClientCommitTs ==
    \A c \in Clients :
        /\ clientPrevCommitTs[c] <= clientCommitTs[c]
        /\ clientCommitTs[c] <= commitTs

\* 4. Atomic Transition / No Torn Reads:
\*    - Every in-flight Transition frame is internally consistent with a SINGLE
\*      atomic committed snapshot `dbHistory[f.toTs]` across all updated queries.
\*    - Every ready client subscription view reflects an exact atomic snapshot
\*      `dbHistory[clientSubTs[c][q]]` (never mixing keys from different commits).
AtomicTransitionNoTornReads ==
    /\ \A c \in Clients :
           \A f \in netToClient[c] :
               f.type = "transition" =>
                   /\ f.toTs <= commitTs
                   /\ \A q \in f.subs :
                          f.updates[q] = QueryEval(q, dbHistory[f.toTs])
    /\ \A c \in Clients :
           \A q \in clientSubs[c] :
               clientSubTs[c][q] # NoTs =>
                   /\ clientSubTs[c][q] <= clientCommitTs[c]
                   /\ clientSubData[c][q] = QueryEval(q, dbHistory[clientSubTs[c][q]])

\* 5. Quiescent Optimistic Convergence:
\*    Whenever client `c` is quiescent (connected to an up-to-date replica,
\*    with no pending mutations, active txs for `c`, or undelivered frames),
\*    its optimistic queue is completely drained and its rendered signal view
\*    for every active subscription equals the exact committed database state.
ClientQuiescent(c) ==
    /\ clientConn[c] # NoReplica
    /\ lastBroadcastTs[clientConn[c]] = commitTs
    /\ pendingClientMuts[c] = {}
    /\ \A t \in TxIds : ~(txs[t].status = "active" /\ txs[t].client = c)
    /\ netToClient[c] = {}

ClientConverged(c) ==
    /\ clientOptQueue[c] = <<>>
    /\ \A q \in clientSubs[c] :
           /\ clientSubTs[c][q] # NoTs
           /\ ClientVisibleView(c, q) = QueryEval(q, db)

QuiescentOptimisticConvergence ==
    \A c \in Clients :
        ClientQuiescent(c) => ClientConverged(c)

-----------------------------------------------------------------------------
(* Liveness Property (under Weak Fairness) *)

\* Eventual Convergence:
\*   1. Every stateless replica eventually tails all commits in `commit_log`.
\*   2. Once a client's subscription set stabilizes and active writes quiesce,
\*      the client eventually drains its optimistic queue and converges to the
\*      exact latest committed database state for every active subscription.
EventualConvergence ==
    /\ \A r \in Replicas : <>[](lastBroadcastTs[r] = commitTs)
    /\ \A c \in Clients :
           (\E r \in Replicas, S \in SUBSET Queries :
               <>[] ( /\ clientConn[c] = r
                      /\ clientSubs[c] = S
                      /\ \A t \in TxIds : txs[t].status # "active" ))
           => <>[] ClientConverged(c)

=============================================================================
