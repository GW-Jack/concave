/-
  Concave ReadSet / WriteSet Soundness & TxContext RYOW Refinement
  Models `zig/core/readset.zig`, `zig/core/wal_store.zig`, and `zig/runtime/tx.zig`
  in pure Lean 4 (`Init` only, zero `sorry`, zero custom axioms).

  Verified properties:
  1. `readSet_soundness_docGet`:
     If `getDoc (applyWrite schema db w) ref ≠ getDoc db ref`, then
     `intersects (docReadSet ref) (writeSet schema db w) = true`.
  2. `readSet_soundness_rangeScan`:
     If `scanRange schema (applyWrite schema db w) q ≠ scanRange schema db q`, then
     `intersects (rangeReadSet q) (writeSet schema db w) = true`
     (covers insert into range, delete from range, and replace/patch moving a doc
     into, out of, or within range via pre-image + post-image index keys).
  3. `readSet_soundness_docGet_ops` & `readSet_soundness_rangeScan_ops`:
     Inductive lift of soundness to arbitrary multi-op transactions `List WriteOp`.
  4. `tx_ryow_refinement` (and `txGet_refinement`):
     Querying `(db, overlay)` via `TxContext`'s merge-and-filter algorithm produces
     the exact same ordered, limited result list as `scanRange schema (applyOverlay db overlay) q`.
-/

namespace Concave.ReadSetSoundness

/-! ## Generic strict total order comparator and canonical sorting -/

def lexCompare {α : Type} (cmp : α → α → Ordering) : List α → List α → Ordering
  | [], [] => .eq
  | [], _ :: _ => .lt
  | _ :: _, [] => .gt
  | a :: as, b :: bs =>
    match cmp a b with
    | .lt => .lt
    | .gt => .gt
    | .eq => lexCompare cmp as bs

structure StrictTotalOrd {α : Type} (cmp : α → α → Ordering) : Prop where
  eq_iff : ∀ a b, cmp a b = .eq ↔ a = b
  swap   : ∀ a b, cmp a b = (cmp b a).swap
  trans  : ∀ a b c, cmp a b = .lt → cmp b c = .lt → cmp a c = .lt

theorem StrictTotalOrd.irrefl {α : Type} {cmp : α → α → Ordering}
    (h : StrictTotalOrd cmp) (a : α) : cmp a a ≠ .lt := by
  have heq : cmp a a = .eq := (h.eq_iff a a).mpr rfl
  rw [heq]
  decide

theorem StrictTotalOrd.gt_iff_lt {α : Type} {cmp : α → α → Ordering}
    (h : StrictTotalOrd cmp) (a b : α) : cmp a b = .gt ↔ cmp b a = .lt := by
  rw [h.swap a b]
  cases cmp b a <;> decide

theorem StrictTotalOrd.ne_imp_lt_or_gt {α : Type} {cmp : α → α → Ordering}
    (h : StrictTotalOrd cmp) {a b : α} (hne : a ≠ b) :
    cmp a b = .lt ∨ cmp b a = .lt := by
  cases hcmp : cmp a b with
  | lt => exact Or.inl rfl
  | eq => exact absurd ((h.eq_iff a b).mp hcmp) hne
  | gt => exact Or.inr ((h.gt_iff_lt a b).mp hcmp)

theorem strictTotalOrd_lexCompare {α : Type} {cmp : α → α → Ordering}
    (h : StrictTotalOrd cmp) : StrictTotalOrd (lexCompare cmp) where
  eq_iff := by
    intro xs ys
    induction xs generalizing ys with
    | nil =>
      cases ys with
      | nil => simp [lexCompare]
      | cons _ _ => simp [lexCompare]
    | cons a as ih =>
      cases ys with
      | nil => simp [lexCompare]
      | cons b bs =>
        simp only [lexCompare]
        cases hcmp : cmp a b with
        | lt =>
          have hne : a ≠ b := fun heq => by
            have := (h.eq_iff a b).mpr heq; rw [hcmp] at this; cases this
          simp [hne]
        | gt =>
          have hne : a ≠ b := fun heq => by
            have := (h.eq_iff a b).mpr heq; rw [hcmp] at this; cases this
          simp [hne]
        | eq =>
          have hab : a = b := (h.eq_iff a b).mp hcmp
          subst hab
          simpa using ih bs
  swap := by
    intro xs ys
    induction xs generalizing ys with
    | nil =>
      cases ys <;> rfl
    | cons a as ih =>
      cases ys with
      | nil => rfl
      | cons b bs =>
        simp only [lexCompare]
        rw [h.swap a b]
        cases cmp b a with
        | lt => rfl
        | gt => rfl
        | eq => exact ih bs
  trans := by
    intro xs ys zs h1 h2
    induction xs generalizing ys zs with
    | nil =>
      cases ys with
      | nil => cases h1
      | cons _ _ =>
        cases zs with
        | nil => cases h2
        | cons _ _ => rfl
    | cons a as ih =>
      cases ys with
      | nil => cases h1
      | cons b bs =>
        cases zs with
        | nil => cases h2
        | cons c cs =>
          simp only [lexCompare] at h1 h2 ⊢
          cases h1' : cmp a b with
          | gt => rw [h1'] at h1; cases h1
          | lt =>
            cases h2' : cmp b c with
            | gt => rw [h2'] at h2; cases h2
            | lt =>
              rw [h.trans a b c h1' h2']
            | eq =>
              have hbc : b = c := (h.eq_iff b c).mp h2'
              subst hbc
              rw [h1']
          | eq =>
            have hab : a = b := (h.eq_iff a b).mp h1'
            subst hab
            rw [h1'] at h1
            cases h2' : cmp a c with
            | gt => rw [h2'] at h2; cases h2
            | lt => rfl
            | eq =>
              rw [h2'] at h2
              exact ih bs cs h1 h2

def cmpNat (a b : Nat) : Ordering :=
  if a < b then .lt else if b < a then .gt else .eq

theorem strictTotalOrd_cmpNat : StrictTotalOrd cmpNat where
  eq_iff := by
    intro a b
    by_cases h1 : a < b
    · simp only [cmpNat, h1, ↓reduceIte]
      constructor
      · intro h; cases h
      · omega
    · by_cases h2 : b < a
      · simp only [cmpNat, h1, h2, ↓reduceIte]
        constructor
        · intro h; cases h
        · omega
      · simp only [cmpNat, h1, h2, ↓reduceIte]
        constructor
        · intro _; omega
        · intro _; exact trivial
  swap := by
    intro a b
    by_cases h1 : a < b
    · have h2 : ¬ b < a := by omega
      simp [cmpNat, h1, h2]
    · by_cases h2 : b < a
      · simp [cmpNat, h1, h2]
      · simp [cmpNat, h1, h2]
  trans := by
    intro a b c h1 h2
    simp only [cmpNat] at h1 h2 ⊢
    split at h1
    · split at h2
      · have : a < c := by omega
        simp [this]
      · split at h2 <;> cases h2
    · split at h1 <;> cases h1

def cmpUInt8 (a b : UInt8) : Ordering := cmpNat a.toNat b.toNat

theorem strictTotalOrd_cmpUInt8 : StrictTotalOrd cmpUInt8 where
  eq_iff := by
    intro a b
    simp only [cmpUInt8, strictTotalOrd_cmpNat.eq_iff]
    constructor
    · intro h; exact UInt8.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq h)
    · intro h; exact congrArg UInt8.toNat h
  swap a b := strictTotalOrd_cmpNat.swap a.toNat b.toNat
  trans a b c := strictTotalOrd_cmpNat.trans a.toNat b.toNat c.toNat

def cmpChar (a b : Char) : Ordering := cmpNat a.val.toNat b.val.toNat

theorem strictTotalOrd_cmpChar : StrictTotalOrd cmpChar where
  eq_iff := by
    intro a b
    simp only [cmpChar, strictTotalOrd_cmpNat.eq_iff]
    constructor
    · intro h; exact Char.ext (UInt32.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq h))
    · intro h; exact congrArg (fun c : Char => c.val.toNat) h
  swap a b := strictTotalOrd_cmpNat.swap a.val.toNat b.val.toNat
  trans a b c := strictTotalOrd_cmpNat.trans a.val.toNat b.val.toNat c.val.toNat

abbrev EncodedKey := List UInt8

def compareBytes : EncodedKey → EncodedKey → Ordering := lexCompare cmpUInt8

theorem strictTotalOrd_compareBytes : StrictTotalOrd compareBytes :=
  strictTotalOrd_lexCompare strictTotalOrd_cmpUInt8

def compareStr (a b : String) : Ordering := lexCompare cmpChar a.toList b.toList

theorem strictTotalOrd_compareStr : StrictTotalOrd compareStr where
  eq_iff := by
    intro a b
    simp only [compareStr, (strictTotalOrd_lexCompare strictTotalOrd_cmpChar).eq_iff]
    exact String.toList_inj
  swap a b := (strictTotalOrd_lexCompare strictTotalOrd_cmpChar).swap a.toList b.toList
  trans a b c := (strictTotalOrd_lexCompare strictTotalOrd_cmpChar).trans a.toList b.toList c.toList

/-! ## Canonical insertion sort and uniqueness theorem -/

def insertSorted {α : Type} (lt : α → α → Bool) (x : α) : List α → List α
  | [] => [x]
  | y :: ys => if lt x y then x :: y :: ys else y :: insertSorted lt x ys

def sortBy {α : Type} (lt : α → α → Bool) : List α → List α
  | [] => []
  | x :: xs => insertSorted lt x (sortBy lt xs)

theorem mem_insertSorted {α : Type} (lt : α → α → Bool) (x z : α) (ys : List α) :
    z ∈ insertSorted lt x ys ↔ z = x ∨ z ∈ ys := by
  induction ys with
  | nil => simp [insertSorted]
  | cons y ys ih =>
    simp only [insertSorted]
    split
    · simp [List.mem_cons]
    · simp only [List.mem_cons, ih]
      constructor
      · intro h
        rcases h with rfl | rfl | h
        · exact Or.inr (Or.inl rfl)
        · exact Or.inl rfl
        · exact Or.inr (Or.inr h)
      · intro h
        rcases h with rfl | rfl | h
        · exact Or.inr (Or.inl rfl)
        · exact Or.inl rfl
        · exact Or.inr (Or.inr h)

theorem mem_sortBy {α : Type} (lt : α → α → Bool) (z : α) (xs : List α) :
    z ∈ sortBy lt xs ↔ z ∈ xs := by
  induction xs with
  | nil => simp [sortBy]
  | cons x xs ih =>
    simp [sortBy, mem_insertSorted, ih]

theorem pairwise_insertSorted {α : Type} {lt : α → α → Bool}
    (htrans : ∀ a b c, lt a b = true → lt b c = true → lt a c = true)
    {x : α} {ys : List α}
    (hnd : x ∉ ys)
    (htotal : ∀ y ∈ ys, x ≠ y → lt x y = true ∨ lt y x = true)
    (hpw : List.Pairwise (fun a b => lt a b = true) ys) :
    List.Pairwise (fun a b => lt a b = true) (insertSorted lt x ys) := by
  induction ys with
  | nil => simp [insertSorted]
  | cons y ys ih =>
    simp only [insertSorted]
    have hpw_cons := List.pairwise_cons.mp hpw
    have hxney : x ≠ y := fun h => hnd (by simp [h])
    have hx_not_ys : x ∉ ys := fun h => hnd (by simp [h])
    split
    · rename_i hxy
      apply List.pairwise_cons.mpr
      refine ⟨?_, hpw⟩
      intro z hz
      rcases List.mem_cons.mp hz with rfl | hzs
      · exact hxy
      · exact htrans x y z hxy (hpw_cons.1 z hzs)
    · rename_i hnotxy
      have hyx : lt y x = true := by
        rcases htotal y (by simp) hxney with h | h
        · exact absurd h hnotxy
        · exact h
      apply List.pairwise_cons.mpr
      refine ⟨?_, ih hx_not_ys (fun z hz => htotal z (by simp [hz])) hpw_cons.2⟩
      intro z hz
      rw [mem_insertSorted] at hz
      rcases hz with rfl | hzs
      · exact hyx
      · exact hpw_cons.1 z hzs

theorem pairwise_sortBy {α : Type} {lt : α → α → Bool}
    (htrans : ∀ a b c, lt a b = true → lt b c = true → lt a c = true)
    {xs : List α}
    (hnd : xs.Nodup)
    (htotal : ∀ a ∈ xs, ∀ b ∈ xs, a ≠ b → lt a b = true ∨ lt b a = true) :
    List.Pairwise (fun a b => lt a b = true) (sortBy lt xs) := by
  induction xs with
  | nil => simp [sortBy]
  | cons x xs ih =>
    have hnd_cons := List.nodup_cons.mp hnd
    have hpw_tail := ih hnd_cons.2 (fun a ha b hb => htotal a (by simp [ha]) b (by simp [hb]))
    apply pairwise_insertSorted htrans
    · intro hx
      exact hnd_cons.1 ((mem_sortBy lt x xs).mp hx)
    · intro y hy hne
      exact htotal x (by simp) y (by simp [(mem_sortBy lt y xs).mp hy]) hne
    · exact hpw_tail

theorem eq_of_pairwise_of_mem_iff {α : Type} {lt : α → α → Bool}
    (hirrefl : ∀ a, lt a a ≠ true)
    (htrans : ∀ a b c, lt a b = true → lt b c = true → lt a c = true) :
    ∀ {l1 l2 : List α},
      List.Pairwise (fun a b => lt a b = true) l1 →
      List.Pairwise (fun a b => lt a b = true) l2 →
      (∀ z, z ∈ l1 ↔ z ∈ l2) →
      l1 = l2
  | [], [], _, _, _ => rfl
  | [], y :: _, _, _, hmem => absurd ((hmem y).mpr (by simp)) (by simp)
  | x :: _, [], _, _, hmem => absurd ((hmem x).mp (by simp)) (by simp)
  | x :: xs, y :: ys, hpw1, hpw2, hmem => by
    have h1 := List.pairwise_cons.mp hpw1
    have h2 := List.pairwise_cons.mp hpw2
    have hxy : x = y := by
      by_cases heq : x = y
      · exact heq
      · have hx_in : x ∈ y :: ys := (hmem x).mp (by simp)
        have hy_in : y ∈ x :: xs := (hmem y).mpr (by simp)
        have hx_ys : x ∈ ys := by
          rcases List.mem_cons.mp hx_in with h | h
          · exact absurd h heq
          · exact h
        have hy_xs : y ∈ xs := by
          rcases List.mem_cons.mp hy_in with h | h
          · exact absurd h.symm heq
          · exact h
        have hlt_xy : lt x y = true := h1.1 y hy_xs
        have hlt_yx : lt y x = true := h2.1 x hx_ys
        exact absurd (htrans x y x hlt_xy hlt_yx) (hirrefl x)
    subst hxy
    congr 1
    apply eq_of_pairwise_of_mem_iff hirrefl htrans h1.2 h2.2
    intro z
    constructor
    · intro hz
      have hne : z ≠ x := fun h => by
        subst h; exact hirrefl z (h1.1 z hz)
      have hz2 : z ∈ x :: ys := (hmem z).mp (by simp [hz])
      rcases List.mem_cons.mp hz2 with h | h
      · exact absurd h hne
      · exact h
    · intro hz
      have hne : z ≠ x := fun h => by
        subst h; exact hirrefl z (h2.1 z hz)
      have hz1 : z ∈ x :: xs := (hmem z).mpr (by simp [hz])
      rcases List.mem_cons.mp hz1 with h | h
      · exact absurd h hne
      · exact h

theorem sortBy_eq_of_mem_iff {α : Type} {lt : α → α → Bool}
    (hirrefl : ∀ a, lt a a ≠ true)
    (htrans : ∀ a b c, lt a b = true → lt b c = true → lt a c = true)
    {xs ys : List α}
    (hnd1 : xs.Nodup) (hnd2 : ys.Nodup)
    (htotal1 : ∀ a ∈ xs, ∀ b ∈ xs, a ≠ b → lt a b = true ∨ lt b a = true)
    (hmem : ∀ z, z ∈ xs ↔ z ∈ ys) :
    sortBy lt xs = sortBy lt ys := by
  have htotal2 : ∀ a ∈ ys, ∀ b ∈ ys, a ≠ b → lt a b = true ∨ lt b a = true := fun a ha b hb =>
    htotal1 a ((hmem a).mpr ha) b ((hmem b).mpr hb)
  have hpw1 := pairwise_sortBy htrans hnd1 htotal1
  have hpw2 := pairwise_sortBy htrans hnd2 htotal2
  apply eq_of_pairwise_of_mem_iff hirrefl htrans hpw1 hpw2
  intro z
  rw [mem_sortBy, mem_sortBy]
  exact hmem z

/-! ## Core Concave data model (`readset.zig`, `storage.zig`, `wal_store.zig`, `tx.zig`) -/

structure DocRef where
  ns    : String
  table : String
  docId : String
deriving DecidableEq, Repr

inductive KeyBound where
  | unbounded
  | included (k : EncodedKey)
  | excluded (k : EncodedKey)
deriving DecidableEq, Repr

/-- Exact mirror of `IndexRangeRead.containsKey` in `zig/core/readset.zig`. -/
def containsKey (start end_ : KeyBound) (k : EncodedKey) : Bool :=
  let aboveStart := match start with
    | .unbounded  => true
    | .included lo => compareBytes k lo != .lt
    | .excluded lo => compareBytes k lo == .gt
  let belowEnd := match end_ with
    | .unbounded  => true
    | .included hi => compareBytes k hi != .gt
    | .excluded hi => compareBytes k hi == .lt
  aboveStart && belowEnd

inductive QueryOrder where
  | asc
  | desc
deriving DecidableEq, Repr

structure IndexQuery where
  ns        : String
  table     : String
  indexName : String
  start     : KeyBound
  end_      : KeyBound
  order     : QueryOrder
  limit     : Option Nat
deriving DecidableEq, Repr

structure IndexRangeRead where
  ns        : String
  table     : String
  indexName : String
  start     : KeyBound
  end_      : KeyBound
deriving DecidableEq, Repr

structure WrittenIndexKey where
  ns         : String
  table      : String
  indexName  : String
  encodedKey : EncodedKey
deriving DecidableEq, Repr

structure ReadSet where
  docReads    : List DocRef
  indexRanges : List IndexRangeRead
deriving DecidableEq, Repr

structure WriteSet where
  docs      : List DocRef
  indexKeys : List WrittenIndexKey
deriving DecidableEq, Repr

def WriteSet.empty : WriteSet := ⟨[], []⟩

def WriteSet.union (a b : WriteSet) : WriteSet :=
  ⟨a.docs ++ b.docs, a.indexKeys ++ b.indexKeys⟩

def docReadSet (ref : DocRef) : ReadSet :=
  ⟨[ref], []⟩

def rangeReadSet (q : IndexQuery) : ReadSet :=
  ⟨[], [{ ns := q.ns, table := q.table, indexName := q.indexName, start := q.start, end_ := q.end_ }]⟩

/-- Exact mirror of `ReadSet.intersects` in `zig/core/readset.zig`. -/
def intersects (rs : ReadSet) (ws : WriteSet) : Bool :=
  ws.docs.any (fun wd => rs.docReads.any (fun rd => rd == wd)) ||
  ws.indexKeys.any (fun wk =>
    rs.indexRanges.any (fun r =>
      r.ns == wk.ns &&
      r.table == wk.table &&
      r.indexName == wk.indexName &&
      containsKey r.start r.end_ wk.encodedKey))

theorem intersects_union (rs : ReadSet) (w1 w2 : WriteSet) :
    intersects rs (w1.union w2) = (intersects rs w1 || intersects rs w2) := by
  simp only [intersects, WriteSet.union, List.any_append]
  cases w1.docs.any _ <;> cases w2.docs.any _ <;>
  cases w1.indexKeys.any _ <;> cases w2.indexKeys.any _ <;> rfl

/-! ## Schema, Document Store, Index Projection, and Writes -/

structure Schema (Doc Patch : Type) where
  indexesFor : String → String → List String
  projectKey : String → String → String → Doc → Option EncodedKey
  applyPatch : Doc → Patch → Doc

/-- Compute the secondary index key for `(ns, table, indexName)` on `doc`,
    returning `none` if `indexName` is not declared on `(ns, table)`. -/
def Schema.indexKey {Doc Patch : Type} (s : Schema Doc Patch)
    (ns table indexName : String) (doc : Doc) : Option EncodedKey :=
  if indexName ∈ s.indexesFor ns table then s.projectKey ns table indexName doc else none

/-- Compute all `(indexName, encodedKey)` pairs for `doc` on `(ns, table)`,
    mirroring `storage.computeIndexEntries` in `zig/core/storage.zig`. -/
def Schema.computeIndexKeys {Doc Patch : Type} (s : Schema Doc Patch)
    (ns table : String) (doc : Doc) : List WrittenIndexKey :=
  (s.indexesFor ns table).filterMap fun idx =>
    (s.projectKey ns table idx doc).map fun k =>
      { ns := ns, table := table, indexName := idx, encodedKey := k }

theorem mem_computeIndexKeys {Doc Patch : Type} (s : Schema Doc Patch)
    (ns table idx : String) (doc : Doc) (k : EncodedKey)
    (h : s.indexKey ns table idx doc = some k) :
    { ns := ns, table := table, indexName := idx, encodedKey := k : WrittenIndexKey } ∈
      s.computeIndexKeys ns table doc := by
  unfold Schema.indexKey at h
  split at h
  · rename_i hmem
    unfold Schema.computeIndexKeys
    rw [List.mem_filterMap]
    exact ⟨idx, hmem, by simp [h]⟩
  · cases h

/-- Association-list map with unique keys, modeling the document store and tx overlay. -/
def NodupKeys {K V : Type} (m : List (K × V)) : Prop :=
  (m.map Prod.fst).Nodup

abbrev DB (Doc : Type) := List (DocRef × Doc)
abbrev Overlay (Doc : Type) := List (DocRef × Option Doc)

def mapLookup {K V : Type} [DecidableEq K] : List (K × V) → K → Option V
  | [], _ => none
  | (k, v) :: rest, q => if k == q then some v else mapLookup rest q

def mapRemove {K V : Type} [DecidableEq K] (m : List (K × V)) (k : K) : List (K × V) :=
  m.filter (fun kv => kv.1 != k)

def mapPut {K V : Type} [DecidableEq K] (m : List (K × V)) (k : K) (v : V) : List (K × V) :=
  (k, v) :: mapRemove m k

theorem mem_iff_mapLookup {K V : Type} [DecidableEq K] {m : List (K × V)}
    (hnd : NodupKeys m) (k : K) (v : V) :
    (k, v) ∈ m ↔ mapLookup m k = some v := by
  induction m with
  | nil => simp [mapLookup]
  | cons hd tl ih =>
    rcases hd with ⟨k0, v0⟩
    have hnd_cons : k0 ∉ tl.map Prod.fst ∧ NodupKeys tl := by
      simpa [NodupKeys, List.nodup_cons] using hnd
    simp only [List.mem_cons, mapLookup, Prod.mk.injEq]
    by_cases hkeq : k0 = k
    · subst hkeq
      simp only [beq_self_eq_true, ↓reduceIte, Option.some.injEq, true_and]
      constructor
      · intro h
        rcases h with rfl | hmem
        · rfl
        · exfalso
          exact hnd_cons.1 (List.mem_map.mpr ⟨(k0, v), hmem, rfl⟩)
      · intro hv
        exact Or.inl hv.symm
    · have hbeq : (k0 == k) = false := beq_false_of_ne hkeq
      simp only [hbeq, Bool.false_eq_true, ↓reduceIte]
      have hne' : k ≠ k0 := Ne.symm hkeq
      simp only [hne', false_and, false_or]
      exact ih hnd_cons.2

theorem nodupKeys_mapRemove {K V : Type} [DecidableEq K] {m : List (K × V)}
    (hnd : NodupKeys m) (k : K) : NodupKeys (mapRemove m k) := by
  induction m with
  | nil => exact List.nodup_nil
  | cons hd tl ih =>
    have hnd_cons : hd.1 ∉ tl.map Prod.fst ∧ NodupKeys tl := by
      simpa [NodupKeys, List.nodup_cons] using hnd
    simp only [mapRemove, List.filter]
    split
    · simp only [NodupKeys, List.map_cons, List.nodup_cons]
      refine ⟨?_, ih hnd_cons.2⟩
      intro hmem
      rw [List.mem_map] at hmem
      rcases hmem with ⟨kv, hkv, heq⟩
      rw [List.mem_filter] at hkv
      exact hnd_cons.1 (List.mem_map.mpr ⟨kv, hkv.1, heq⟩)
    · exact ih hnd_cons.2

theorem nodupKeys_mapPut {K V : Type} [DecidableEq K] {m : List (K × V)}
    (hnd : NodupKeys m) (k : K) (v : V) : NodupKeys (mapPut m k v) := by
  simp only [mapPut, NodupKeys, List.map_cons, List.nodup_cons]
  refine ⟨?_, nodupKeys_mapRemove hnd k⟩
  intro hmem
  rw [List.mem_map] at hmem
  rcases hmem with ⟨kv, hkv, heq⟩
  simp only [mapRemove, List.mem_filter] at hkv
  have : (kv.1 != k) = false := by simp [heq]
  rw [this] at hkv
  cases hkv.2

theorem mapLookup_mapRemove {K V : Type} [DecidableEq K] (m : List (K × V)) (k q : K) :
    mapLookup (mapRemove m k) q = if q = k then none else mapLookup m q := by
  induction m with
  | nil =>
    simp [mapRemove, mapLookup]
  | cons hd tl ih =>
    rcases hd with ⟨k0, v0⟩
    by_cases h0 : k0 = k
    · subst h0
      have hrm : mapRemove ((k0, v0) :: tl) k0 = mapRemove tl k0 := by
        simp [mapRemove]
      rw [hrm, ih]
      by_cases hq : q = k0
      · subst hq; simp
      · have hne : (k0 == q) = false := beq_false_of_ne (Ne.symm hq)
        simp [mapLookup, hq, hne]
    · have hrm : mapRemove ((k0, v0) :: tl) k = (k0, v0) :: mapRemove tl k := by
        have hbne : (k0 != k) = true := bne_iff_ne.mpr h0
        simp [mapRemove, hbne]
      rw [hrm]
      simp only [mapLookup]
      by_cases hq : q = k
      · subst hq
        have hne : (k0 == q) = false := beq_false_of_ne h0
        simp [hne, ih]
      · simp only [hq, ↓reduceIte]
        by_cases hkq : k0 = q
        · subst hkq; simp
        · have hne : (k0 == q) = false := beq_false_of_ne hkq
          simp [hne, ih, hq]

theorem mapLookup_mapPut {K V : Type} [DecidableEq K] (m : List (K × V)) (k q : K) (v : V) :
    mapLookup (mapPut m k v) q = if q = k then some v else mapLookup m q := by
  simp only [mapPut, mapLookup]
  by_cases hq : q = k
  · subst hq; simp
  · have hne : (k == q) = false := beq_false_of_ne (Ne.symm hq)
    simp [hne, hq, mapLookup_mapRemove]

def getDoc {Doc : Type} (db : DB Doc) (ref : DocRef) : Option Doc :=
  mapLookup db ref

def setDoc {Doc : Type} (db : DB Doc) (ref : DocRef) (doc : Doc) : DB Doc :=
  mapPut db ref doc

def deleteDoc {Doc : Type} (db : DB Doc) (ref : DocRef) : DB Doc :=
  mapRemove db ref

/-! ## Write operations & WriteSet construction (`wal_store.zig`) -/

inductive WriteOp (Doc Patch : Type) where
  | insert  (ref : DocRef) (doc : Doc)
  | replace (ref : DocRef) (doc : Doc)
  | patch   (ref : DocRef) (p : Patch)
  | delete  (ref : DocRef)
deriving Repr

def WriteOp.ref {Doc Patch : Type} : WriteOp Doc Patch → DocRef
  | .insert r _  => r
  | .replace r _ => r
  | .patch r _   => r
  | .delete r    => r

/-- Apply a single write operation to the document store, matching `WalStore.applyOpLocked`. -/
def applyWrite {Doc Patch : Type} (s : Schema Doc Patch) (db : DB Doc) :
    WriteOp Doc Patch → DB Doc
  | .insert ref doc => setDoc db ref doc
  | .replace ref doc =>
    match getDoc db ref with
    | none   => db
    | some _ => setDoc db ref doc
  | .patch ref p =>
    match getDoc db ref with
    | none     => db
    | some old => setDoc db ref (s.applyPatch old p)
  | .delete ref =>
    match getDoc db ref with
    | none   => db
    | some _ => deleteDoc db ref

theorem nodupKeys_applyWrite {Doc Patch : Type} (s : Schema Doc Patch)
    {db : DB Doc} (hnd : NodupKeys db) (w : WriteOp Doc Patch) :
    NodupKeys (applyWrite s db w) := by
  cases w with
  | insert ref doc => exact nodupKeys_mapPut hnd ref doc
  | replace ref doc =>
    simp only [applyWrite]
    cases getDoc db ref
    · exact hnd
    · exact nodupKeys_mapPut hnd ref doc
  | patch ref p =>
    simp only [applyWrite]
    cases getDoc db ref
    · exact hnd
    · exact nodupKeys_mapPut hnd ref _
  | delete ref =>
    simp only [applyWrite]
    cases getDoc db ref
    · exact hnd
    · exact nodupKeys_mapRemove hnd ref

/-- Compute the `WriteSet` for a single write operation, recording the doc ref
    plus BOTH pre-image AND post-image index keys across all declared indexes. -/
def writeSet {Doc Patch : Type} (s : Schema Doc Patch) (db : DB Doc) :
    WriteOp Doc Patch → WriteSet
  | .insert ref doc =>
    let preKeys := match getDoc db ref with
      | none     => []
      | some old => s.computeIndexKeys ref.ns ref.table old
    let postKeys := s.computeIndexKeys ref.ns ref.table doc
    ⟨[ref], preKeys ++ postKeys⟩
  | .replace ref doc =>
    match getDoc db ref with
    | none => WriteSet.empty
    | some old =>
      ⟨[ref], s.computeIndexKeys ref.ns ref.table old ++ s.computeIndexKeys ref.ns ref.table doc⟩
  | .patch ref p =>
    match getDoc db ref with
    | none => WriteSet.empty
    | some old =>
      let updated := s.applyPatch old p
      ⟨[ref], s.computeIndexKeys ref.ns ref.table old ++ s.computeIndexKeys ref.ns ref.table updated⟩
  | .delete ref =>
    match getDoc db ref with
    | none => WriteSet.empty
    | some old =>
      ⟨[ref], s.computeIndexKeys ref.ns ref.table old⟩

/-- Multi-op transaction write execution & cumulative `WriteSet`, matching `WalStore.commitTx`. -/
def applyWrites {Doc Patch : Type} (s : Schema Doc Patch) :
    DB Doc → List (WriteOp Doc Patch) → DB Doc
  | db, [] => db
  | db, w :: ws => applyWrites s (applyWrite s db w) ws

def writeSetOfOps {Doc Patch : Type} (s : Schema Doc Patch) :
    DB Doc → List (WriteOp Doc Patch) → WriteSet
  | _, [] => WriteSet.empty
  | db, w :: ws => (writeSet s db w).union (writeSetOfOps s (applyWrite s db w) ws)

theorem nodupKeys_applyWrites {Doc Patch : Type} (s : Schema Doc Patch)
    {db : DB Doc} (hnd : NodupKeys db) (ops : List (WriteOp Doc Patch)) :
    NodupKeys (applyWrites s db ops) := by
  induction ops generalizing db with
  | nil => exact hnd
  | cons w ws ih => exact ih (nodupKeys_applyWrite s hnd w)

/-! ## Secondary index range scan (`wal_store.zig` & `tx.zig`) -/

abbrev KeyedEntry (Doc : Type) := EncodedKey × DocRef × Doc

def entryCompare {Doc : Type} (ord : QueryOrder) (a b : KeyedEntry Doc) : Ordering :=
  let base := match compareBytes a.1 b.1 with
    | .lt => .lt
    | .gt => .gt
    | .eq => compareStr a.2.1.docId b.2.1.docId
  match ord with
  | .asc  => base
  | .desc => base.swap

def entryLt {Doc : Type} (ord : QueryOrder) (a b : KeyedEntry Doc) : Bool :=
  entryCompare ord a b == .lt

theorem entryLt_irrefl {Doc : Type} (ord : QueryOrder) (a : KeyedEntry Doc) :
    entryLt ord a a ≠ true := by
  have hb : compareBytes a.1 a.1 = .eq := (strictTotalOrd_compareBytes.eq_iff _ _).mpr rfl
  have hs : compareStr a.2.1.docId a.2.1.docId = .eq :=
    (strictTotalOrd_compareStr.eq_iff _ _).mpr rfl
  cases ord <;> simp [entryLt, entryCompare, hb, hs]

theorem entryLt_trans {Doc : Type} (ord : QueryOrder) (a b c : KeyedEntry Doc)
    (h1 : entryLt ord a b = true) (h2 : entryLt ord b c = true) :
    entryLt ord a c = true := by
  simp only [entryLt, entryCompare, beq_iff_eq] at h1 h2 ⊢
  cases ord with
  | asc =>
    cases hb1 : compareBytes a.1 b.1 with
    | gt => rw [hb1] at h1; cases h1
    | lt =>
      cases hb2 : compareBytes b.1 c.1 with
      | gt => rw [hb2] at h2; cases h2
      | lt => rw [strictTotalOrd_compareBytes.trans a.1 b.1 c.1 hb1 hb2]
      | eq =>
        have hbc := (strictTotalOrd_compareBytes.eq_iff b.1 c.1).mp hb2
        rw [← hbc, hb1]
    | eq =>
      have hab := (strictTotalOrd_compareBytes.eq_iff a.1 b.1).mp hb1
      rw [hb1] at h1
      rw [hab]
      cases hb2 : compareBytes b.1 c.1 with
      | gt => rw [hb2] at h2; cases h2
      | lt => rfl
      | eq =>
        rw [hb2] at h2
        exact strictTotalOrd_compareStr.trans _ _ _ h1 h2
  | desc =>
    -- In desc mode, `base.swap = .lt` iff `base = .gt`, i.e., `compareBytes b a = .lt` or equal + `compareStr b a = .lt`
    cases hb1 : compareBytes a.1 b.1 with
    | lt => rw [hb1] at h1; cases h1
    | gt =>
      have hba : compareBytes b.1 a.1 = .lt := (strictTotalOrd_compareBytes.gt_iff_lt _ _).mp hb1
      cases hb2 : compareBytes b.1 c.1 with
      | lt => rw [hb2] at h2; cases h2
      | gt =>
        have hcb : compareBytes c.1 b.1 = .lt := (strictTotalOrd_compareBytes.gt_iff_lt _ _).mp hb2
        have hca : compareBytes c.1 a.1 = .lt := strictTotalOrd_compareBytes.trans _ _ _ hcb hba
        have hac : compareBytes a.1 c.1 = .gt := (strictTotalOrd_compareBytes.gt_iff_lt _ _).mpr hca
        rw [hac]; rfl
      | eq =>
        have hbc := (strictTotalOrd_compareBytes.eq_iff b.1 c.1).mp hb2
        rw [← hbc, hb1]; rfl
    | eq =>
      have hab := (strictTotalOrd_compareBytes.eq_iff a.1 b.1).mp hb1
      rw [hb1] at h1
      rw [hab]
      have hs1 : compareStr a.2.1.docId b.2.1.docId = .gt := by
        cases h : compareStr a.2.1.docId b.2.1.docId <;> simp [h] at h1 ⊢
      have hsba : compareStr b.2.1.docId a.2.1.docId = .lt :=
        (strictTotalOrd_compareStr.gt_iff_lt _ _).mp hs1
      cases hb2 : compareBytes b.1 c.1 with
      | lt => rw [hb2] at h2; cases h2
      | gt => rfl
      | eq =>
        rw [hb2] at h2
        have hs2 : compareStr b.2.1.docId c.2.1.docId = .gt := by
          cases h : compareStr b.2.1.docId c.2.1.docId <;> simp [h] at h2 ⊢
        have hscb : compareStr c.2.1.docId b.2.1.docId = .lt :=
          (strictTotalOrd_compareStr.gt_iff_lt _ _).mp hs2
        have hsca : compareStr c.2.1.docId a.2.1.docId = .lt :=
          strictTotalOrd_compareStr.trans _ _ _ hscb hsba
        have hsac : compareStr a.2.1.docId c.2.1.docId = .gt :=
          (strictTotalOrd_compareStr.gt_iff_lt _ _).mpr hsca
        rw [hsac]; rfl

theorem entryLt_total_of_docId_ne {Doc : Type} (ord : QueryOrder)
    {a b : KeyedEntry Doc} (hne : a.2.1.docId ≠ b.2.1.docId) :
    entryLt ord a b = true ∨ entryLt ord b a = true := by
  simp only [entryLt, entryCompare, beq_iff_eq]
  cases hb : compareBytes a.1 b.1 with
  | lt =>
    have hgt : compareBytes b.1 a.1 = .gt := (strictTotalOrd_compareBytes.gt_iff_lt _ _).mpr hb
    cases ord
    · exact Or.inl rfl
    · exact Or.inr (by simp [hgt])
  | gt =>
    have hlt : compareBytes b.1 a.1 = .lt := (strictTotalOrd_compareBytes.gt_iff_lt _ _).mp hb
    cases ord
    · exact Or.inr (by simp [hlt])
    · exact Or.inl rfl
  | eq =>
    have hbeq : compareBytes b.1 a.1 = .eq := by
      have := (strictTotalOrd_compareBytes.eq_iff _ _).mp hb
      exact (strictTotalOrd_compareBytes.eq_iff _ _).mpr this.symm
    rcases strictTotalOrd_compareStr.ne_imp_lt_or_gt hne with hs | hs
    · have hsgt : compareStr b.2.1.docId a.2.1.docId = .gt :=
        (strictTotalOrd_compareStr.gt_iff_lt _ _).mpr hs
      cases ord
      · exact Or.inl (by simp [hs])
      · exact Or.inr (by simp [hbeq, hsgt])
    · have hsgt : compareStr a.2.1.docId b.2.1.docId = .gt :=
        (strictTotalOrd_compareStr.gt_iff_lt _ _).mpr hs
      cases ord
      · exact Or.inr (by simp [hbeq, hs])
      · exact Or.inl (by simp [hsgt])

/-- Filter & project all documents in `db` that belong to `q`'s table and fall in `q`'s index range. -/
def filterRangeEntries {Doc Patch : Type} (s : Schema Doc Patch) (db : DB Doc) (q : IndexQuery) :
    List (KeyedEntry Doc) :=
  db.filterMap fun (ref, doc) =>
    if ref.ns == q.ns && ref.table == q.table then
      match s.indexKey q.ns q.table q.indexName doc with
      | some k => if containsKey q.start q.end_ k then some (k, ref, doc) else none
      | none   => none
    else
      none

def applyLimit {α : Type} (lim : Option Nat) (xs : List α) : List α :=
  match lim with
  | none   => xs
  | some n => xs.take n

/-- Reference secondary index range scan over `db`. -/
def scanRange {Doc Patch : Type} (s : Schema Doc Patch) (db : DB Doc) (q : IndexQuery) :
    List (DocRef × Doc) :=
  let entries := filterRangeEntries s db q
  let sorted  := sortBy (entryLt q.order) entries
  applyLimit q.limit (sorted.map Prod.snd)

theorem mem_filterRangeEntries {Doc Patch : Type} (s : Schema Doc Patch)
    {db : DB Doc} (hnd : NodupKeys db) (q : IndexQuery)
    (e : KeyedEntry Doc) :
    e ∈ filterRangeEntries s db q ↔
      e.2.1.ns = q.ns ∧
      e.2.1.table = q.table ∧
      getDoc db e.2.1 = some e.2.2 ∧
      s.indexKey q.ns q.table q.indexName e.2.2 = some e.1 ∧
      containsKey q.start q.end_ e.1 = true := by
  rcases e with ⟨k, ref, doc⟩
  dsimp only
  unfold filterRangeEntries
  rw [List.mem_filterMap]
  constructor
  · rintro ⟨⟨r, d⟩, hmem, hsome⟩
    by_cases htbl : (r.ns == q.ns && r.table == q.table) = true
    · simp only [htbl, ↓reduceIte] at hsome
      cases hk : s.indexKey q.ns q.table q.indexName d with
      | none => simp [hk] at hsome
      | some k0 =>
        simp only [hk] at hsome
        by_cases hc : containsKey q.start q.end_ k0 = true
        · simp only [hc, ↓reduceIte, Option.some.injEq, Prod.mk.injEq] at hsome
          rcases hsome with ⟨rfl, rfl, rfl⟩
          simp only [Bool.and_eq_true, beq_iff_eq] at htbl
          exact ⟨htbl.1, htbl.2, (mem_iff_mapLookup hnd r d).mp hmem, hk, hc⟩
        · simp [hc] at hsome
    · simp [htbl] at hsome
  · rintro ⟨hns, htbl, hget, hk, hc⟩
    refine ⟨(ref, doc), (mem_iff_mapLookup hnd ref doc).mpr hget, ?_⟩
    simp [hns, htbl, hk, hc]

theorem nodup_filterRangeEntries {Doc Patch : Type} (s : Schema Doc Patch)
    {db : DB Doc} (hnd : NodupKeys db) (q : IndexQuery) :
    (filterRangeEntries s db q).Nodup := by
  induction db with
  | nil => simp [filterRangeEntries]
  | cons hd tl ih =>
    rcases hd with ⟨r, d⟩
    have hnd_cons : r ∉ tl.map Prod.fst ∧ NodupKeys tl := by
      simpa [NodupKeys, List.nodup_cons] using hnd
    simp only [filterRangeEntries, List.filterMap_cons]
    split
    · exact ih hnd_cons.2
    · rename_i e he
      rw [List.nodup_cons]
      refine ⟨?_, ih hnd_cons.2⟩
      intro hmem
      have htl := (mem_filterRangeEntries s hnd_cons.2 q e).mp hmem
      have hre : e.2.1 = r := by
        split at he
        · cases hk : s.indexKey q.ns q.table q.indexName d with
          | none => simp [hk] at he
          | some k0 =>
            simp only [hk] at he
            split at he
            · simp only [Option.some.injEq] at he
              rw [← he]
            · cases he
        · cases he
      rw [hre] at htl
      have hin := (mem_iff_mapLookup hnd_cons.2 r e.2.2).mpr htl.2.2.1
      exact hnd_cons.1 (List.mem_map.mpr ⟨(r, e.2.2), hin, rfl⟩)

theorem filterRangeEntries_docId_ne {Doc Patch : Type} (s : Schema Doc Patch)
    {db : DB Doc} (hnd : NodupKeys db) (q : IndexQuery)
    {a b : KeyedEntry Doc}
    (ha : a ∈ filterRangeEntries s db q)
    (hb : b ∈ filterRangeEntries s db q)
    (hne : a ≠ b) :
    a.2.1.docId ≠ b.2.1.docId := by
  intro hid
  have ha' := (mem_filterRangeEntries s hnd q a).mp ha
  have hb' := (mem_filterRangeEntries s hnd q b).mp hb
  have href : a.2.1 = b.2.1 := by
    cases ra : a.2.1
    cases rb : b.2.1
    simp only [ra, rb] at ha' hb' hid
    congr
    · exact ha'.1.trans hb'.1.symm
    · exact ha'.2.1.trans hb'.2.1.symm
  have hdoc : a.2.2 = b.2.2 := by
    have h1 := ha'.2.2.1
    have h2 := hb'.2.2.1
    rw [href] at h1
    rw [h1] at h2
    exact Option.some.inj h2
  have hkey : a.1 = b.1 := by
    have h1 := ha'.2.2.2.1
    have h2 := hb'.2.2.2.1
    rw [hdoc] at h1
    rw [h1] at h2
    exact Option.some.inj h2
  apply hne
  rcases a with ⟨ka, ra, da⟩
  rcases b with ⟨kb, rb, db_⟩
  simp only at hkey href hdoc
  subst hkey; subst href; subst hdoc; rfl

theorem scanRange_eq_of_entries_equiv {Doc Patch : Type} (s : Schema Doc Patch)
    {db1 db2 : DB Doc} (hnd1 : NodupKeys db1) (hnd2 : NodupKeys db2) (q : IndexQuery)
    (hequiv : ∀ e, e ∈ filterRangeEntries s db1 q ↔ e ∈ filterRangeEntries s db2 q) :
    scanRange s db1 q = scanRange s db2 q := by
  unfold scanRange
  dsimp only
  have hsort : sortBy (entryLt q.order) (filterRangeEntries s db1 q) =
               sortBy (entryLt q.order) (filterRangeEntries s db2 q) := by
    apply sortBy_eq_of_mem_iff (entryLt_irrefl q.order) (entryLt_trans q.order)
      (nodup_filterRangeEntries s hnd1 q) (nodup_filterRangeEntries s hnd2 q)
    · intro a ha b hb hne
      exact entryLt_total_of_docId_ne q.order (filterRangeEntries_docId_ne s hnd1 q ha hb hne)
    · exact hequiv
  rw [hsort]

/-! ## Theorem 1 & 2: ReadSet / WriteSet Soundness -/

/-- Helper: if a write op modifies `db` at `ref`, then `ref` is recorded in `writeSet`. -/
private theorem doc_mem_writeSet_of_getDoc_ne {Doc Patch : Type}
    (s : Schema Doc Patch) (db : DB Doc) (w : WriteOp Doc Patch) (ref : DocRef)
    (hdiff : getDoc (applyWrite s db w) ref ≠ getDoc db ref) :
    ref ∈ (writeSet s db w).docs := by
  cases w with
  | insert r doc =>
    simp only [applyWrite, getDoc, setDoc, mapLookup_mapPut] at hdiff
    by_cases h : ref = r
    · subst h; simp [writeSet]
    · simp [h] at hdiff
  | replace r doc =>
    simp only [applyWrite, writeSet] at hdiff ⊢
    cases hget : getDoc db r with
    | none => rw [hget] at hdiff; exact absurd rfl hdiff
    | some old =>
      rw [hget] at hdiff
      simp only [getDoc, setDoc, mapLookup_mapPut] at hdiff
      by_cases h : ref = r
      · subst h; simp
      · simp [h] at hdiff
  | patch r p =>
    simp only [applyWrite, writeSet] at hdiff ⊢
    cases hget : getDoc db r with
    | none => rw [hget] at hdiff; exact absurd rfl hdiff
    | some old =>
      rw [hget] at hdiff
      simp only [getDoc, setDoc, mapLookup_mapPut] at hdiff
      by_cases h : ref = r
      · subst h; simp
      · simp [h] at hdiff
  | delete r =>
    simp only [applyWrite, writeSet] at hdiff ⊢
    cases hget : getDoc db r with
    | none => rw [hget] at hdiff; exact absurd rfl hdiff
    | some old =>
      rw [hget] at hdiff
      simp only [getDoc, deleteDoc, mapLookup_mapRemove] at hdiff
      by_cases h : ref = r
      · subst h; simp
      · simp [h] at hdiff

/-- **Theorem 1 (`readSet_soundness_docGet`)**:
    Zero false negatives for point reads: if a write changes `getDoc db ref`,
    then `docReadSet ref` MUST intersect `writeSet s db w`. -/
theorem readSet_soundness_docGet {Doc Patch : Type}
    (s : Schema Doc Patch) (db : DB Doc) (w : WriteOp Doc Patch) (ref : DocRef)
    (hdiff : getDoc (applyWrite s db w) ref ≠ getDoc db ref) :
    intersects (docReadSet ref) (writeSet s db w) = true := by
  have hmem := doc_mem_writeSet_of_getDoc_ne s db w ref hdiff
  simp only [intersects, docReadSet, Bool.or_eq_true, List.any_eq_true, beq_iff_eq]
  exact Or.inl ⟨ref, hmem, ref, by simp, rfl⟩

/-- Key invariant of Concave's pre-image + post-image `WriteSet`:
    whenever a write changes `getDoc db ref`, EVERY index key of the pre-image doc (if any)
    AND EVERY index key of the post-image doc (if any) is recorded in `(writeSet s db w).indexKeys`. -/
private theorem pre_post_keys_in_writeSet {Doc Patch : Type}
    (s : Schema Doc Patch) (db : DB Doc) (w : WriteOp Doc Patch) (ref : DocRef)
    (hdiff : getDoc (applyWrite s db w) ref ≠ getDoc db ref) :
    (∀ old idx k, getDoc db ref = some old →
      s.indexKey ref.ns ref.table idx old = some k →
      { ns := ref.ns, table := ref.table, indexName := idx, encodedKey := k : WrittenIndexKey } ∈
        (writeSet s db w).indexKeys) ∧
    (∀ newDoc idx k, getDoc (applyWrite s db w) ref = some newDoc →
      s.indexKey ref.ns ref.table idx newDoc = some k →
      { ns := ref.ns, table := ref.table, indexName := idx, encodedKey := k : WrittenIndexKey } ∈
        (writeSet s db w).indexKeys) := by
  cases w with
  | insert r doc =>
    have hr : ref = r := by
      simp only [applyWrite, getDoc, setDoc, mapLookup_mapPut] at hdiff
      by_cases h : ref = r
      · exact h
      · simp [h] at hdiff
    subst hr
    constructor
    · intro old idx k hget hk
      simp only [writeSet, hget, List.mem_append]
      exact Or.inl (mem_computeIndexKeys s ref.ns ref.table idx old k hk)
    · intro newDoc idx k hget hk
      simp only [applyWrite, getDoc, setDoc, mapLookup_mapPut, ↓reduceIte, Option.some.injEq] at hget
      subst hget
      simp only [writeSet, List.mem_append]
      exact Or.inr (mem_computeIndexKeys s ref.ns ref.table idx doc k hk)
  | replace r doc =>
    cases hdb : getDoc db r with
    | none =>
      simp only [applyWrite, hdb] at hdiff
      exact absurd rfl hdiff
    | some old0 =>
      have hr : ref = r := by
        simp only [applyWrite, hdb] at hdiff
        simp only [getDoc, setDoc, mapLookup_mapPut] at hdiff
        by_cases h : ref = r
        · exact h
        · simp [h] at hdiff
      subst hr
      constructor
      · intro old idx k hget hk
        rw [hdb] at hget
        have hEq : old0 = old := Option.some.inj hget
        subst hEq
        simp only [writeSet, hdb, List.mem_append]
        exact Or.inl (mem_computeIndexKeys s ref.ns ref.table idx old0 k hk)
      · intro newDoc idx k hget hk
        simp only [applyWrite, hdb] at hget
        simp only [getDoc, setDoc, mapLookup_mapPut, ↓reduceIte, Option.some.injEq] at hget
        subst hget
        simp only [writeSet, hdb, List.mem_append]
        exact Or.inr (mem_computeIndexKeys s ref.ns ref.table idx doc k hk)
  | patch r p =>
    cases hdb : getDoc db r with
    | none =>
      simp only [applyWrite, hdb] at hdiff
      exact absurd rfl hdiff
    | some old0 =>
      have hr : ref = r := by
        simp only [applyWrite, hdb] at hdiff
        simp only [getDoc, setDoc, mapLookup_mapPut] at hdiff
        by_cases h : ref = r
        · exact h
        · simp [h] at hdiff
      subst hr
      constructor
      · intro old idx k hget hk
        rw [hdb] at hget
        have hEq : old0 = old := Option.some.inj hget
        subst hEq
        simp only [writeSet, hdb, List.mem_append]
        exact Or.inl (mem_computeIndexKeys s ref.ns ref.table idx old0 k hk)
      · intro newDoc idx k hget hk
        simp only [applyWrite, hdb] at hget
        simp only [getDoc, setDoc, mapLookup_mapPut, ↓reduceIte, Option.some.injEq] at hget
        subst hget
        simp only [writeSet, hdb, List.mem_append]
        exact Or.inr (mem_computeIndexKeys s ref.ns ref.table idx (s.applyPatch old0 p) k hk)
  | delete r =>
    cases hdb : getDoc db r with
    | none =>
      simp only [applyWrite, hdb] at hdiff
      exact absurd rfl hdiff
    | some old0 =>
      have hr : ref = r := by
        simp only [applyWrite, hdb] at hdiff
        simp only [getDoc, deleteDoc, mapLookup_mapRemove] at hdiff
        by_cases h : ref = r
        · exact h
        · simp [h] at hdiff
      subst hr
      constructor
      · intro old idx k hget hk
        rw [hdb] at hget
        have hEq : old0 = old := Option.some.inj hget
        subst hEq
        simp only [writeSet, hdb]
        exact mem_computeIndexKeys s ref.ns ref.table idx old0 k hk
      · intro newDoc _ _ hget _
        simp only [applyWrite, hdb] at hget
        simp only [getDoc, deleteDoc, mapLookup_mapRemove, ↓reduceIte] at hget
        cases hget

/-- **Theorem 2 (`readSet_soundness_rangeScan`)**:
    Zero false negatives for bounded secondary index range scans:
    if `scanRange s (applyWrite s db w) q ≠ scanRange s db q`, then
    `intersects (rangeReadSet q) (writeSet s db w) = true`.
    Covers insert into range, delete from range, and replace/patch moving a document
    into, out of, or within the scanned range. -/
theorem readSet_soundness_rangeScan {Doc Patch : Type}
    (s : Schema Doc Patch) {db : DB Doc} (hnd : NodupKeys db)
    (w : WriteOp Doc Patch) (q : IndexQuery)
    (hdiff : scanRange s (applyWrite s db w) q ≠ scanRange s db q) :
    intersects (rangeReadSet q) (writeSet s db w) = true := by
  -- Prove by contrapositive: if intersects = false, then scanRange is unchanged.
  cases hint : intersects (rangeReadSet q) (writeSet s db w) with
  | true => rfl
  | false =>
    exfalso
    apply hdiff
    apply scanRange_eq_of_entries_equiv s (nodupKeys_applyWrite s hnd w) hnd q
    intro e
    rw [mem_filterRangeEntries s (nodupKeys_applyWrite s hnd w) q e,
        mem_filterRangeEntries s hnd q e]
    rcases e with ⟨k, ref, doc⟩
    dsimp only
    by_cases hget_eq : getDoc (applyWrite s db w) ref = getDoc db ref
    · rw [hget_eq]
    · have ⟨hpre, hpost⟩ := pre_post_keys_in_writeSet s db w ref hget_eq
      constructor
      · rintro ⟨hns, htbl, hget_new, hk, hc⟩
        exfalso
        have hwk : { ns := q.ns, table := q.table, indexName := q.indexName, encodedKey := k : WrittenIndexKey } ∈
            (writeSet s db w).indexKeys := by
          rw [← hns, ← htbl]
          exact hpost doc q.indexName k hget_new (by rw [hns, htbl]; exact hk)
        have htrue : intersects (rangeReadSet q) (writeSet s db w) = true := by
          simp only [intersects, rangeReadSet, Bool.or_eq_true, List.any_eq_true,
                     Bool.and_eq_true, beq_iff_eq]
          exact Or.inr ⟨{ ns := q.ns, table := q.table, indexName := q.indexName, encodedKey := k },
                        hwk,
                        { ns := q.ns, table := q.table, indexName := q.indexName, start := q.start, end_ := q.end_ },
                        by simp, ⟨⟨⟨rfl, rfl⟩, rfl⟩, hc⟩⟩
        rw [hint] at htrue; cases htrue
      · rintro ⟨hns, htbl, hget_old, hk, hc⟩
        exfalso
        have hwk : { ns := q.ns, table := q.table, indexName := q.indexName, encodedKey := k : WrittenIndexKey } ∈
            (writeSet s db w).indexKeys := by
          rw [← hns, ← htbl]
          exact hpre doc q.indexName k hget_old (by rw [hns, htbl]; exact hk)
        have htrue : intersects (rangeReadSet q) (writeSet s db w) = true := by
          simp only [intersects, rangeReadSet, Bool.or_eq_true, List.any_eq_true,
                     Bool.and_eq_true, beq_iff_eq]
          exact Or.inr ⟨{ ns := q.ns, table := q.table, indexName := q.indexName, encodedKey := k },
                        hwk,
                        { ns := q.ns, table := q.table, indexName := q.indexName, start := q.start, end_ := q.end_ },
                        by simp, ⟨⟨⟨rfl, rfl⟩, rfl⟩, hc⟩⟩
        rw [hint] at htrue; cases htrue

/-- Multi-op transaction lift of `readSet_soundness_docGet`. -/
theorem readSet_soundness_docGet_ops {Doc Patch : Type}
    (s : Schema Doc Patch) (db : DB Doc) (ops : List (WriteOp Doc Patch)) (ref : DocRef)
    (hdiff : getDoc (applyWrites s db ops) ref ≠ getDoc db ref) :
    intersects (docReadSet ref) (writeSetOfOps s db ops) = true := by
  induction ops generalizing db with
  | nil => exact absurd rfl hdiff
  | cons w ws ih =>
    simp only [applyWrites, writeSetOfOps, intersects_union, Bool.or_eq_true] at hdiff ⊢
    by_cases h1 : getDoc (applyWrite s db w) ref = getDoc db ref
    · exact Or.inr (ih (applyWrite s db w) (by rw [h1]; exact hdiff))
    · exact Or.inl (readSet_soundness_docGet s db w ref h1)

/-- Multi-op transaction lift of `readSet_soundness_rangeScan`. -/
theorem readSet_soundness_rangeScan_ops {Doc Patch : Type}
    (s : Schema Doc Patch) {db : DB Doc} (hnd : NodupKeys db)
    (ops : List (WriteOp Doc Patch)) (q : IndexQuery)
    (hdiff : scanRange s (applyWrites s db ops) q ≠ scanRange s db q) :
    intersects (rangeReadSet q) (writeSetOfOps s db ops) = true := by
  induction ops generalizing db with
  | nil => exact absurd rfl hdiff
  | cons w ws ih =>
    simp only [applyWrites, writeSetOfOps, intersects_union, Bool.or_eq_true] at hdiff ⊢
    cases hint1 : intersects (rangeReadSet q) (writeSet s db w) with
    | true => exact Or.inl rfl
    | false =>
      have hsame : scanRange s (applyWrite s db w) q = scanRange s db q := by
        by_cases hne : scanRange s (applyWrite s db w) q = scanRange s db q
        · exact hne
        · have ht := readSet_soundness_rangeScan s hnd w q hne
          rw [hint1] at ht; cases ht
      exact Or.inr (ih (nodupKeys_applyWrite s hnd w) (by rw [hsame]; exact hdiff))

/-! ## Theorem 3: `TxContext` Read-Your-Own-Writes (RYOW) Overlay Refinement (`zig/runtime/tx.zig`) -/

/-- Apply an overlay of pending transaction writes (`some doc` = upsert, `none` = delete tombstone)
    directly to the base database. -/
def applyOverlay {Doc : Type} (db : DB Doc) : Overlay Doc → DB Doc
  | [] => db
  | (ref, some doc) :: rest => setDoc (applyOverlay db rest) ref doc
  | (ref, none)     :: rest => deleteDoc (applyOverlay db rest) ref

theorem nodupKeys_applyOverlay {Doc : Type} {db : DB Doc} (hnd : NodupKeys db) (ov : Overlay Doc) :
    NodupKeys (applyOverlay db ov) := by
  induction ov with
  | nil => exact hnd
  | cons hd tl ih =>
    rcases hd with ⟨ref, optDoc⟩
    cases optDoc with
    | none     => exact nodupKeys_mapRemove ih ref
    | some doc => exact nodupKeys_mapPut ih ref doc

/-- `getDoc (applyOverlay db ov) ref` returns the overlay entry if present, else `getDoc db ref`. -/
theorem getDoc_applyOverlay {Doc : Type} (db : DB Doc) (ov : Overlay Doc) (ref : DocRef) :
    getDoc (applyOverlay db ov) ref =
      match mapLookup ov ref with
      | some optDoc => optDoc
      | none        => getDoc db ref := by
  induction ov with
  | nil => simp [applyOverlay, mapLookup]
  | cons hd tl ih =>
    rcases hd with ⟨r, optDoc⟩
    simp only [mapLookup]
    by_cases h : r = ref
    · subst h
      cases optDoc with
      | none => simp [applyOverlay, getDoc, deleteDoc, mapLookup_mapRemove]
      | some doc => simp [applyOverlay, getDoc, setDoc, mapLookup_mapPut]
    · have hbeq : (r == ref) = false := beq_false_of_ne h
      have hne : ref ≠ r := Ne.symm h
      cases optDoc with
      | none =>
        simp only [applyOverlay, getDoc, deleteDoc, mapLookup_mapRemove, hne, hbeq, ↓reduceIte,
                   Bool.false_eq_true]
        exact ih
      | some doc =>
        simp only [applyOverlay, getDoc, setDoc, mapLookup_mapPut, hne, hbeq, ↓reduceIte,
                   Bool.false_eq_true]
        exact ih

/-- `TxContext.get` (`zig/runtime/tx.zig` lines 55–64). -/
def txGet {Doc : Type} (db : DB Doc) (ov : Overlay Doc) (ref : DocRef) : Option Doc :=
  match mapLookup ov ref with
  | some optDoc => optDoc
  | none        => getDoc db ref

theorem txGet_refinement {Doc : Type} (db : DB Doc) (ov : Overlay Doc) (ref : DocRef) :
    txGet db ov ref = getDoc (applyOverlay db ov) ref :=
  (getDoc_applyOverlay db ov ref).symm

/-- Merge overlay entries belonging to `(ns, table)` onto `base` (`zig/runtime/tx.zig` lines 116–128). -/
def mergeTableOverlay {Doc : Type} (base : DB Doc) (ov : Overlay Doc) (ns table : String) :
    DB Doc :=
  match ov with
  | [] => base
  | (ref, optDoc) :: rest =>
    let tailMerged := mergeTableOverlay base rest ns table
    if ref.ns == ns && ref.table == table then
      match optDoc with
      | some doc => setDoc tailMerged ref doc
      | none     => deleteDoc tailMerged ref
    else
      tailMerged

theorem nodupKeys_mergeTableOverlay {Doc : Type} {base : DB Doc} (hnd : NodupKeys base)
    (ov : Overlay Doc) (ns table : String) :
    NodupKeys (mergeTableOverlay base ov ns table) := by
  induction ov with
  | nil => exact hnd
  | cons hd tl ih =>
    rcases hd with ⟨ref, optDoc⟩
    simp only [mergeTableOverlay]
    split
    · cases optDoc with
      | none     => exact nodupKeys_mapRemove ih ref
      | some doc => exact nodupKeys_mapPut ih ref doc
    · exact ih

theorem getDoc_mergeTableOverlay {Doc : Type} (base : DB Doc) (ov : Overlay Doc)
    (ns table : String) (ref : DocRef) (hns : ref.ns = ns) (htbl : ref.table = table) :
    getDoc (mergeTableOverlay base ov ns table) ref =
      match mapLookup ov ref with
      | some optDoc => optDoc
      | none        => getDoc base ref := by
  induction ov with
  | nil => simp [mergeTableOverlay, mapLookup]
  | cons hd tl ih =>
    rcases hd with ⟨r, optDoc⟩
    simp only [mergeTableOverlay, mapLookup]
    by_cases heq : r = ref
    · subst heq
      simp only [hns, htbl, beq_self_eq_true, Bool.and_self, ↓reduceIte]
      cases optDoc with
      | none     => simp [getDoc, deleteDoc, mapLookup_mapRemove]
      | some doc => simp [getDoc, setDoc, mapLookup_mapPut]
    · have hbeq : (r == ref) = false := beq_false_of_ne heq
      have hne : ref ≠ r := Ne.symm heq
      simp only [hbeq, Bool.false_eq_true, ↓reduceIte]
      split
      · cases optDoc with
        | none =>
          simp only [getDoc, deleteDoc, mapLookup_mapRemove, hne, ↓reduceIte]
          exact ih
        | some doc =>
          simp only [getDoc, setDoc, mapLookup_mapPut, hne, ↓reduceIte]
          exact ih
      · exact ih

/-- Exact model of `TxContext.scanIndex` (`zig/runtime/tx.zig` lines 66–200):
    1. Fast path: if `ov` has no pending mutations for `(q.ns, q.table)`, return `scanRange s db q`.
    2. Merge-and-filter path:
       - Scan base `db` for `q` with `limit := none`.
       - Merge all pending overlay entries for `(q.ns, q.table)` onto `base`
         (removing deleted/replaced docs, inserting/updating overlayed docs even if
         they moved into range from outside!).
       - Re-project and re-filter by `q`'s index range, sort by `(encodedKey, docId)` in
         `q.order`, and apply `q.limit`. -/
def txScanRange {Doc Patch : Type} (s : Schema Doc Patch) (db : DB Doc)
    (ov : Overlay Doc) (q : IndexQuery) : List (DocRef × Doc) :=
  let hasPending := ov.any (fun (r, _) => r.ns == q.ns && r.table == q.table)
  if !hasPending then
    scanRange s db q
  else
    let base   := scanRange s db { q with limit := none }
    let merged := mergeTableOverlay base ov q.ns q.table
    scanRange s merged q

private theorem nodupKeys_scanRange_unbounded {Doc Patch : Type} (s : Schema Doc Patch)
    {db : DB Doc} (hnd : NodupKeys db) (q : IndexQuery) :
    NodupKeys (scanRange s db { q with limit := none }) := by
  unfold scanRange applyLimit
  have hnd_e : (filterRangeEntries s db { q with limit := none }).Nodup :=
    nodup_filterRangeEntries s hnd _
  -- Show the refs in `sortBy ...` have no duplicates because distinct entries have distinct docIds (hence distinct refs).
  have hpw := pairwise_sortBy (entryLt_trans q.order) hnd_e (fun a ha b hb hne =>
    entryLt_total_of_docId_ne q.order (filterRangeEntries_docId_ne s hnd _ ha hb hne))
  have hnd_sorted : (sortBy (entryLt q.order) (filterRangeEntries s db { q with limit := none })).Nodup := by
    exact List.Pairwise.imp (fun {a b} hlt heq => by subst heq; exact entryLt_irrefl q.order a hlt) hpw
  -- Map `Prod.fst ∘ Prod.snd` is injective on `sortBy ...` because all elements are in `filterRangeEntries`.
  have hsub : ∀ e ∈ sortBy (entryLt q.order) (filterRangeEntries s db { q with limit := none }),
      e ∈ filterRangeEntries s db { q with limit := none } := fun e he => (mem_sortBy _ _ _).mp he
  unfold NodupKeys
  rw [List.map_map]
  -- Prove `(l.map (fun e => e.2.1)).Nodup` by induction on `l` using `hnd_sorted` and `hsub`.
  generalize hl : sortBy (entryLt q.order) (filterRangeEntries s db { q with limit := none }) = l at hnd_sorted hsub
  clear hl hpw hnd_e
  induction l with
  | nil => simp
  | cons x xs ih =>
    have hnd_cons := List.nodup_cons.mp hnd_sorted
    simp only [List.map_cons, Function.comp_apply, List.nodup_cons]
    refine ⟨?_, ih hnd_cons.2 (fun e he => hsub e (by simp [he]))⟩
    intro hmem
    rw [List.mem_map] at hmem
    rcases hmem with ⟨y, hy, heq⟩
    have hne : x ≠ y := fun h => hnd_cons.1 (h ▸ hy)
    have hdocne := filterRangeEntries_docId_ne s hnd _ (hsub x (by simp)) (hsub y (by simp [hy])) hne
    exact hdocne (congrArg DocRef.docId heq.symm)

private theorem getDoc_scanRange_unbounded {Doc Patch : Type} (s : Schema Doc Patch)
    {db : DB Doc} (hnd : NodupKeys db) (q : IndexQuery) (ref : DocRef) (doc : Doc) :
    getDoc (scanRange s db { q with limit := none }) ref = some doc ↔
      ref.ns = q.ns ∧
      ref.table = q.table ∧
      getDoc db ref = some doc ∧
      ∃ k, s.indexKey q.ns q.table q.indexName doc = some k ∧
           containsKey q.start q.end_ k = true := by
  have hnd_base := nodupKeys_scanRange_unbounded s hnd q
  unfold getDoc
  rw [← mem_iff_mapLookup hnd_base ref doc]
  unfold scanRange applyLimit
  rw [List.mem_map]
  constructor
  · rintro ⟨⟨k, r, d⟩, hmem, hpair⟩
    simp only [Prod.mk.injEq] at hpair
    rcases hpair with ⟨rfl, rfl⟩
    rw [mem_sortBy, mem_filterRangeEntries s hnd { q with limit := none }] at hmem
    exact ⟨hmem.1, hmem.2.1, hmem.2.2.1, k, hmem.2.2.2.1, hmem.2.2.2.2⟩
  · rintro ⟨hns, htbl, hget, k, hk, hc⟩
    refine ⟨(k, ref, doc), ?_, rfl⟩
    rw [mem_sortBy, mem_filterRangeEntries s hnd { q with limit := none }]
    exact ⟨hns, htbl, hget, hk, hc⟩

/-- **Theorem 3 (`tx_ryow_refinement`)**:
    Querying `(db, overlay)` via `TxContext`'s merge-and-filter algorithm (`txScanRange`)
    produces the EXACT same ordered, limited result list as scanning the materialized
    overlayed database `scanRange s (applyOverlay db ov) q`. -/
theorem tx_ryow_refinement {Doc Patch : Type} (s : Schema Doc Patch)
    {db : DB Doc} (hnd : NodupKeys db) (ov : Overlay Doc) (q : IndexQuery) :
    txScanRange s db ov q = scanRange s (applyOverlay db ov) q := by
  unfold txScanRange
  by_cases hp : ov.any (fun (r, _) => r.ns == q.ns && r.table == q.table) = true
  · -- Merge-and-filter path (pending writes exist in this table)
    simp only [hp, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
    have hnd_base := nodupKeys_scanRange_unbounded s hnd q
    have hnd_merged := nodupKeys_mergeTableOverlay hnd_base ov q.ns q.table
    have hnd_app := nodupKeys_applyOverlay hnd ov
    apply scanRange_eq_of_entries_equiv s hnd_merged hnd_app q
    intro e
    rw [mem_filterRangeEntries s hnd_merged q e,
        mem_filterRangeEntries s hnd_app q e]
    rcases e with ⟨k, ref, doc⟩
    dsimp only
    constructor
    · rintro ⟨hns, htbl, hget_m, hk, hc⟩
      rw [getDoc_mergeTableOverlay _ ov q.ns q.table ref hns htbl] at hget_m
      rw [getDoc_applyOverlay]
      cases hlook : mapLookup ov ref with
      | some optDoc =>
        rw [hlook] at hget_m
        exact ⟨hns, htbl, hget_m, hk, hc⟩
      | none =>
        rw [hlook] at hget_m
        have hb := (getDoc_scanRange_unbounded s hnd q ref doc).mp hget_m
        exact ⟨hns, htbl, hb.2.2.1, hk, hc⟩
    · rintro ⟨hns, htbl, hget_a, hk, hc⟩
      rw [getDoc_applyOverlay] at hget_a
      rw [getDoc_mergeTableOverlay _ ov q.ns q.table ref hns htbl]
      cases hlook : mapLookup ov ref with
      | some optDoc =>
        rw [hlook] at hget_a
        exact ⟨hns, htbl, hget_a, hk, hc⟩
      | none =>
        rw [hlook] at hget_a
        have hb : getDoc (scanRange s db { q with limit := none }) ref = some doc :=
          (getDoc_scanRange_unbounded s hnd q ref doc).mpr ⟨hns, htbl, hget_a, k, hk, hc⟩
        exact ⟨hns, htbl, hb, hk, hc⟩
  · -- Fast path (no pending writes in `(q.ns, q.table)`): overlay cannot touch any doc in `q`'s table!
    have hp_false : ov.any (fun (r, _) => r.ns == q.ns && r.table == q.table) = false := by
      cases h : ov.any (fun (r, _) => r.ns == q.ns && r.table == q.table)
      · rfl
      · exact absurd h hp
    simp only [hp_false, Bool.not_false, ↓reduceIte]
    have hnd_app := nodupKeys_applyOverlay hnd ov
    apply scanRange_eq_of_entries_equiv s hnd hnd_app q
    intro e
    rw [mem_filterRangeEntries s hnd q e,
        mem_filterRangeEntries s hnd_app q e]
    rcases e with ⟨k, ref, doc⟩
    dsimp only
    have hlook_none : ∀ (ov' : Overlay Doc),
        ov'.any (fun (r, _) => r.ns == q.ns && r.table == q.table) = false →
        ref.ns = q.ns → ref.table = q.table → mapLookup ov' ref = none := by
      intro ov' hpf hns htbl
      induction ov' with
      | nil => rfl
      | cons hd tl ih =>
        rcases hd with ⟨r, optDoc⟩
        simp only [List.any_cons, Bool.or_eq_false_iff] at hpf
        have hne : r ≠ ref := by
          intro heq
          subst heq
          have : (r.ns == q.ns && r.table == q.table) = true := by simp [hns, htbl]
          rw [this] at hpf
          cases hpf.1
        have hbeq : (r == ref) = false := beq_false_of_ne hne
        simp only [mapLookup, hbeq, Bool.false_eq_true, ↓reduceIte]
        exact ih hpf.2
    constructor
    · rintro ⟨hns, htbl, hget, hk, hc⟩
      refine ⟨hns, htbl, ?_, hk, hc⟩
      rw [getDoc_applyOverlay, hlook_none ov hp_false hns htbl]
      exact hget
    · rintro ⟨hns, htbl, hget, hk, hc⟩
      refine ⟨hns, htbl, ?_, hk, hc⟩
      rw [getDoc_applyOverlay, hlook_none ov hp_false hns htbl] at hget
      exact hget

end Concave.ReadSetSoundness

#print axioms Concave.ReadSetSoundness.readSet_soundness_docGet
#print axioms Concave.ReadSetSoundness.readSet_soundness_rangeScan
#print axioms Concave.ReadSetSoundness.readSet_soundness_docGet_ops
#print axioms Concave.ReadSetSoundness.readSet_soundness_rangeScan_ops
#print axioms Concave.ReadSetSoundness.txGet_refinement
#print axioms Concave.ReadSetSoundness.tx_ryow_refinement
