/-
  Concave Analytics Formal Specification & Machine-Checked Proofs (Lean 4)
  Pure `Init` only — ZERO `sorry`, ZERO custom axioms.

  Matches implementation:
  - `packages/analytics/Props.roc`     (Prop upsert, `$set` / `$set_once` precedence, NoDupKeys)
  - `packages/analytics/Flags.roc`     (kill switch, rollout=0, total multivariate variant selection)
  - `packages/analytics/Analytics.roc` (acyclic alias forest, root preservation, idempotent resolve)
  - `packages/analytics/Insights.roc`  (funnel monotonicity, retention bounds & period-0 exactness)

  Check with:
    lean specs/lean/AnalyticsProofs.lean
-/

namespace Concave.Analytics

/-! ## 1. Structured Properties (`Props.roc`) -/

structure PropKV where
  key : String
  val : String
  deriving DecidableEq, Repr

/-- Lookup first matching key (matches canonical deduplicated property list). -/
def lookupProp : List PropKV → String → Option String
  | [], _ => none
  | p :: ps, k => if p.key = k then some p.val else lookupProp ps k

/-- Remove all entries with key `k`. -/
def removeKey : List PropKV → String → List PropKV
  | [], _ => []
  | p :: ps, k => if p.key = k then removeKey ps k else p :: removeKey ps k

/-- Deduplicating upsert matching `Props.upsert`: replaces first match, drops duplicates, or appends. -/
def upsertProp : List PropKV → String → String → List PropKV
  | [], k, v => [{ key := k, val := v }]
  | p :: ps, k, v =>
      if p.key = k then
        { key := k, val := v } :: removeKey ps k
      else
        p :: upsertProp ps k v

/-- No duplicate keys invariant. -/
def NoDupKeys : List PropKV → Prop
  | [] => True
  | p :: ps => lookupProp ps p.key = none ∧ NoDupKeys ps

theorem lookup_removeKey_eq (ps : List PropKV) (k : String) :
    lookupProp (removeKey ps k) k = none := by
  induction ps with
  | nil => rfl
  | cons p ps ih =>
      simp only [removeKey]
      by_cases h : p.key = k
      · simp [h, ih]
      · simp [h, lookupProp, ih]

theorem lookup_removeKey_ne (ps : List PropKV) {k k' : String} (hne : k' ≠ k) :
    lookupProp (removeKey ps k) k' = lookupProp ps k' := by
  induction ps with
  | nil => rfl
  | cons p ps ih =>
      simp only [removeKey]
      by_cases h : p.key = k
      · simp [h, lookupProp, Ne.symm hne, ih]
      · simp only [h, ↓reduceIte, lookupProp]
        by_cases h' : p.key = k'
        · simp [h']
        · simp [h', ih]

theorem removeKey_noDup (ps : List PropKV) (k : String) (h : NoDupKeys ps) :
    NoDupKeys (removeKey ps k) := by
  induction ps with
  | nil => trivial
  | cons p ps ih =>
      rcases h with ⟨hnone, hps⟩
      simp only [removeKey]
      by_cases hk : p.key = k
      · simp [hk, ih hps]
      · simp only [hk, ↓reduceIte, NoDupKeys]
        exact ⟨by rw [lookup_removeKey_ne ps hk]; exact hnone, ih hps⟩

theorem upsertProp_lookup_eq (ps : List PropKV) (k v : String) :
    lookupProp (upsertProp ps k v) k = some v := by
  induction ps with
  | nil => simp [upsertProp, lookupProp]
  | cons p ps ih =>
      simp only [upsertProp]
      by_cases h : p.key = k
      · simp [h, lookupProp]
      · simp [h, lookupProp, ih]

theorem upsertProp_lookup_ne (ps : List PropKV) {k k' : String} (v : String) (hne : k' ≠ k) :
    lookupProp (upsertProp ps k v) k' = lookupProp ps k' := by
  induction ps with
  | nil =>
      simp [upsertProp, lookupProp, Ne.symm hne]
  | cons p ps ih =>
      simp only [upsertProp]
      by_cases h : p.key = k
      · simp [h, lookupProp, Ne.symm hne, lookup_removeKey_ne ps hne]
      · simp only [h, ↓reduceIte, lookupProp]
        by_cases h' : p.key = k'
        · simp [h']
        · simp [h', ih]

theorem upsertProp_noDup (ps : List PropKV) (k v : String) (h : NoDupKeys ps) :
    NoDupKeys (upsertProp ps k v) := by
  induction ps with
  | nil => simp [upsertProp, NoDupKeys, lookupProp]
  | cons p ps ih =>
      rcases h with ⟨hnone, hps⟩
      simp only [upsertProp]
      by_cases hk : p.key = k
      · simp only [hk, ↓reduceIte, NoDupKeys]
        exact ⟨lookup_removeKey_eq ps k, removeKey_noDup ps k hps⟩
      · simp only [hk, ↓reduceIte, NoDupKeys]
        exact ⟨by rw [upsertProp_lookup_ne ps v hk]; exact hnone, ih hps⟩

/-- PostHog `$set`: overwrites or inserts every non-empty key in `updates`. -/
def mergeSet (base updates : List PropKV) : List PropKV :=
  updates.foldl (fun acc u => if u.key = "" then acc else upsertProp acc u.key u.val) base

/-- PostHog `$set_once`: inserts only keys not already present in `base`. -/
def mergeSetOnce (base updates : List PropKV) : List PropKV :=
  updates.foldl
    (fun acc u =>
      if u.key = "" then acc
      else match lookupProp acc u.key with
        | some _ => acc
        | none => upsertProp acc u.key u.val)
    base

theorem mergeSet_noDup (base updates : List PropKV) (h : NoDupKeys base) :
    NoDupKeys (mergeSet base updates) := by
  unfold mergeSet
  induction updates generalizing base with
  | nil => exact h
  | cons u us ih =>
      simp only [List.foldl_cons]
      by_cases he : u.key = ""
      · simp only [he, ↓reduceIte]
        exact ih base h
      · simp only [he, ↓reduceIte]
        exact ih (upsertProp base u.key u.val) (upsertProp_noDup base u.key u.val h)

theorem mergeSetOnce_noDup (base updates : List PropKV) (h : NoDupKeys base) :
    NoDupKeys (mergeSetOnce base updates) := by
  unfold mergeSetOnce
  induction updates generalizing base with
  | nil => exact h
  | cons u us ih =>
      simp only [List.foldl_cons]
      by_cases he : u.key = ""
      · simp only [he, ↓reduceIte]
        exact ih base h
      · simp only [he, ↓reduceIte]
        cases hlu : lookupProp base u.key with
        | some _ => exact ih base h
        | none => exact ih (upsertProp base u.key u.val) (upsertProp_noDup base u.key u.val h)

/-- PostHog `$set_once` NEVER overwrites a key that is already present in `base`. -/
theorem mergeSetOnce_preserves_existing (base updates : List PropKV) (k v : String)
    (hex : lookupProp base k = some v) :
    lookupProp (mergeSetOnce base updates) k = some v := by
  unfold mergeSetOnce
  induction updates generalizing base with
  | nil => exact hex
  | cons u us ih =>
      simp only [List.foldl_cons]
      by_cases he : u.key = ""
      · simp only [he, ↓reduceIte]
        exact ih base hex
      · simp only [he, ↓reduceIte]
        cases hlu : lookupProp base u.key with
        | some _ => exact ih base hex
        | none =>
            have hne : k ≠ u.key := by
              intro heq
              subst heq
              rw [hex] at hlu
              cases hlu
            apply ih
            rw [upsertProp_lookup_ne base u.val hne]
            exact hex

/-! ## 2. Feature Flags & Multivariate Variant Partitioning (`Flags.roc`) -/

structure FlagVariant where
  key : String
  weight : Nat
  deriving DecidableEq, Repr

def totalWeight : List FlagVariant → Nat
  | [] => 0
  | v :: vs => v.weight + totalWeight vs

def selectVariant : List FlagVariant → Nat → Option FlagVariant
  | [], _ => none
  | v :: vs, pick =>
      if pick < v.weight then
        some v
      else
        selectVariant vs (pick - v.weight)

/-- Totality & membership: for ANY pick < totalWeight variants, selectVariant succeeds
    and returns an element of `variants` (never falls through). -/
theorem selectVariant_total (vs : List FlagVariant) (pick : Nat) (h : pick < totalWeight vs) :
    ∃ v, selectVariant vs pick = some v ∧ v ∈ vs := by
  induction vs generalizing pick with
  | nil =>
      simp [totalWeight] at h
  | cons v vs ih =>
      simp only [selectVariant]
      by_cases hlt : pick < v.weight
      · exact ⟨v, by simp [hlt], List.Mem.head vs⟩
      · simp only [hlt, ↓reduceIte]
        have hrem : pick - v.weight < totalWeight vs := by
          simp only [totalWeight] at h
          omega
        rcases ih (pick - v.weight) hrem with ⟨chosen, hsel, hmem⟩
        exact ⟨chosen, hsel, List.Mem.tail v hmem⟩

structure FlagEval where
  enabled : Bool
  variant : String
  deriving DecidableEq, Repr

def evalFlagModel (active : Bool) (filterOk : Bool) (rolloutPct bucketPct : Nat)
    (variants : List FlagVariant) (pick : Nat) : FlagEval :=
  if !active then
    { enabled := false, variant := "" }
  else if !filterOk then
    { enabled := false, variant := "" }
  else if rolloutPct = 0 then
    { enabled := false, variant := "" }
  else if rolloutPct < 100 && bucketPct ≥ rolloutPct then
    { enabled := false, variant := "" }
  else
    match variants with
    | [] => { enabled := true, variant := "true" }
    | _ =>
        match selectVariant variants pick with
        | some v => { enabled := true, variant := v.key }
        | none => { enabled := true, variant := "true" }

theorem flag_kill_switch_sound (filterOk : Bool) (rolloutPct bucketPct : Nat)
    (vs : List FlagVariant) (pick : Nat) :
    (evalFlagModel false filterOk rolloutPct bucketPct vs pick).enabled = false := by
  rfl

theorem flag_filter_mismatch_sound (active : Bool) (rolloutPct bucketPct : Nat)
    (vs : List FlagVariant) (pick : Nat) :
    (evalFlagModel active false rolloutPct bucketPct vs pick).enabled = false := by
  cases active <;> rfl

theorem flag_rollout_zero_sound (active filterOk : Bool) (bucketPct : Nat)
    (vs : List FlagVariant) (pick : Nat) :
    (evalFlagModel active filterOk 0 bucketPct vs pick).enabled = false := by
  cases active <;> cases filterOk <;> rfl

/-! ## 3. Alias Forest Acyclicity & Root Stability (`Analytics.roc`) -/

/-- Partial alias map: `f x = some y` means `x` is aliased to `y`; `f x = none` means `x` is a root. -/
abbrev AliasMap (Id : Type) := Id → Option Id

/-- A well-formed alias forest admits a strict rank witness `rank : Id → Nat` where every edge
    strictly increases rank. This guarantees strict acyclicity (zero cycles of any length). -/
def IsForest {Id : Type} (f : AliasMap Id) (rank : Id → Nat) : Prop :=
  ∀ u v, f u = some v → rank u < rank v

/-- Empty alias map is trivially a forest. -/
theorem empty_isForest {Id : Type} : IsForest (fun _ : Id => none) (fun _ => 0) := by
  intro _ _ h
  cases h

/-- Helper: adding edge `src → dst` to an alias map. -/
def addAlias {Id : Type} [DecidableEq Id] (f : AliasMap Id) (src dst : Id) : AliasMap Id :=
  fun x => if x = src then some dst else f x

/-- Core Theorem: Linking an unaliased root `src` to a distinct root `dst` ALWAYS preserves
    strict forest acyclicity (models fixed `identify!` and `alias!` in `Analytics.roc`). -/
theorem linkRoots_preserves_forest {Id : Type} [DecidableEq Id]
    (f : AliasMap Id) (rank : Id → Nat) (src dst : Id)
    (hForest : IsForest f rank)
    (hSrcRoot : f src = none)
    (hDstRoot : f dst = none)
    (hNe : src ≠ dst) :
    ∃ rank', IsForest (addAlias f src dst) rank' := by
  let rank' : Id → Nat := fun x => if x = dst then max (rank dst) (rank src + 1) else rank x
  refine ⟨rank', ?_⟩
  intro u v huv
  simp only [addAlias] at huv
  by_cases hu : u = src
  · subst hu
    simp only [↓reduceIte, Option.some.injEq] at huv
    subst huv
    -- New edge `src → dst`: rank' src = rank src < max (rank dst) (rank src + 1) = rank' dst
    simp only [rank', hNe, ↓reduceIte]
    omega
  · simp only [hu, ↓reduceIte] at huv
    -- Existing edge `u → v` in `f`: since `dst` is a root (`f dst = none`), `u ≠ dst`!
    have huDst : u ≠ dst := by
      intro heq
      subst heq
      rw [hDstRoot] at huv
      cases huv
    have hOld : rank u < rank v := hForest u v huv
    simp only [rank', huDst, ↓reduceIte]
    by_cases hv : v = dst
    · subst hv
      simp only [↓reduceIte]
      omega
    · simp only [hv, ↓reduceIte]
      exact hOld

/-- In any well-formed forest, no non-empty path can return to its start (zero cycles of any length). -/
inductive Path {Id : Type} (f : AliasMap Id) : Id → Id → Prop where
  | step {u v} : f u = some v → Path f u v
  | trans {u v w} : f u = some v → Path f v w → Path f u w

theorem path_increases_rank {Id : Type} (f : AliasMap Id) (rank : Id → Nat)
    (hForest : IsForest f rank) {u v : Id} (hp : Path f u v) :
    rank u < rank v := by
  induction hp with
  | step h => exact hForest _ _ h
  | trans h _ ih => exact Nat.lt_trans (hForest _ _ h) ih

theorem forest_acyclic {Id : Type} (f : AliasMap Id) (rank : Id → Nat)
    (hForest : IsForest f rank) (u : Id) :
    ¬ Path f u u := by
  intro hcycle
  have hlt := path_increases_rank f rank hForest hcycle
  exact Nat.lt_irrefl _ hlt

/-! ## 4. Funnel Monotonicity (`Insights.roc`) -/

/-- Count how many persons reached at least `stepIdx` (matching `Insights.compute_funnel`). -/
def funnelStepCount (maxSteps : List Nat) (stepIdx : Nat) : Nat :=
  (maxSteps.filter (fun m => decide (stepIdx ≤ m))).length

theorem funnel_monotone (maxSteps : List Nat) (i : Nat) :
    funnelStepCount maxSteps (i + 1) ≤ funnelStepCount maxSteps i := by
  unfold funnelStepCount
  induction maxSteps with
  | nil => simp
  | cons m ms ih =>
      simp only [List.filter_cons]
      by_cases h1 : i + 1 ≤ m
      · have h0 : i ≤ m := by omega
        simp [h1, h0]
        omega
      · by_cases h0 : i ≤ m
        · simp [h1, h0]
          omega
        · simp [h1, h0]
          exact ih

theorem funnel_le_total_entered (maxSteps : List Nat) (i : Nat) :
    funnelStepCount maxSteps i ≤ maxSteps.length := by
  unfold funnelStepCount
  induction maxSteps with
  | nil => simp
  | cons m ms ih =>
      simp only [List.filter_cons, List.length_cons]
      by_cases h : i ≤ m
      · simp [h]; omega
      · simp [h]; omega

/-! ## 5. Retention Bounds & Exact Period-0 Retention (`Insights.roc`) -/

/-- Count cohort members who triggered `return_event` in target period. -/
def retainedCount {Person : Type} (members : List Person) (returned : Person → Bool) : Nat :=
  (members.filter returned).length

theorem retention_le_cohort_size {Person : Type} (members : List Person) (returned : Person → Bool) :
    retainedCount members returned ≤ members.length := by
  unfold retainedCount
  induction members with
  | nil => simp
  | cons m ms ih =>
      simp only [List.filter_cons, List.length_cons]
      cases returned m <;> simp <;> omega

/-- When `cohort_event = return_event`, every cohort member returned in offset 0 (`retained = size`). -/
theorem retention_period_zero_exact {Person : Type} (members : List Person)
    (returned : Person → Bool) (hall : ∀ m ∈ members, returned m = true) :
    retainedCount members returned = members.length := by
  unfold retainedCount
  induction members with
  | nil => simp
  | cons m ms ih =>
      have hm : returned m = true := hall m (List.Mem.head ms)
      have hms : ∀ x ∈ ms, returned x = true := fun x hx => hall x (List.Mem.tail m hx)
      simp [hm, ih hms]

-- Verify zero custom axioms / zero `sorry` on every main theorem:
#print axioms upsertProp_noDup
#print axioms mergeSet_noDup
#print axioms mergeSetOnce_preserves_existing
#print axioms selectVariant_total
#print axioms linkRoots_preserves_forest
#print axioms forest_acyclic
#print axioms funnel_monotone
#print axioms retention_le_cohort_size
#print axioms retention_period_zero_exact

end Concave.Analytics
