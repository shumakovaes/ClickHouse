# Stable ordered aggregation for lagged autocorrelation

## 1. Scope and conventions

Fix a nonnegative maximum lag \(L\). Observations are finite real values
\((k,x_k)\) with explicit integer keys. A nonempty aggregate represents exactly
one dense key interval

\[
I=[\ell,r]\cap\mathbb Z,
\qquad n=r-\ell+1,
\]

with one observation at every key in the interval. Keys determine sequence
order; the order in which partial states reach the merge function does not.

For lag \(h\), the ordered pairs are

\[
\mathcal P_h(I)=\{(x_k,x_{k+h}):\ell\le k\le r-h\}.
\]

Only \(1\le h\le\min(L,n-1)\) is meaningful. The conventional ACF in this
document uses the common all-observation denominator, and the Ljung--Box
statistic uses that ACF.

This specification assumes dense, equally spaced observations. Missing keys,
duplicate keys, and intentional time-series boundaries are validation errors,
not observations to be silently skipped.

## 2. Numerically stable moment primitives

### 2.1 Univariate centered moment

For values \(z_1,\ldots,z_N\), store

\[
U=(N,\mu,M_2),\qquad
\mu=\frac1N\sum_i z_i,\qquad
M_2=\sum_i(z_i-\mu)^2.
\]

The empty value is \((0,0,0)\). To combine nonempty summaries \(U_A\) and
\(U_B\), let

\[
N=N_A+N_B,\qquad \delta=\mu_B-\mu_A.
\]

Then the Chan merge is

\[
\mu=\mu_A+\delta\frac{N_B}{N},
\qquad
M_2=M_{2,A}+M_{2,B}+\delta^2\frac{N_A N_B}{N}.
\tag{1}
\]

An empty operand is an identity. A singleton \(z\) is \((1,z,0)\).

### 2.2 Centered bivariate co-moment

For ordered pairs \((u_i,v_i)\), store

\[
B=(N,\bar u,\bar v,C),
\]

where

\[
\bar u=\frac1N\sum_i u_i,
\qquad
\bar v=\frac1N\sum_i v_i,
\qquad
C=\sum_i(u_i-\bar u)(v_i-\bar v).
\]

For nonempty \(B_A,B_B\), put

\[
N=N_A+N_B,
\quad \delta_u=\bar u_B-\bar u_A,
\quad \delta_v=\bar v_B-\bar v_A.
\]

Their stable parallel merge is

\[
\bar u=\bar u_A+\delta_u\frac{N_B}{N},
\qquad
\bar v=\bar v_A+\delta_v\frac{N_B}{N},
\]

\[
C=C_A+C_B+\delta_u\delta_v\frac{N_A N_B}{N}.
\tag{2}
\]

Again, the empty summary is an identity and a singleton pair \((u,v)\) is
\((1,u,v,0)\). Equation (2) is a covariance analogue of (1); it avoids forming
large raw products and later subtracting nearly equal terms.

## 3. Aggregate state and invariants

A state is

\[
S_L(I)=\bigl(L,\ell,r,n,U,B_1,\ldots,B_L,P,Q\bigr),
\]

or a distinguished empty state carrying only \(L\). Its fields are:

- \(U=(n,\mu,M_2)\), the centered moment of all observations;
- \(B_h=(N_h,a_h,b_h,C_h)\), the bivariate centered moment of
  \(\mathcal P_h(I)\);
- \(P\), the first \(\min(L,n)\) keyed observations;
- \(Q\), the last \(\min(L,n)\) keyed observations.

The following are representation invariants, not optional checks:

\[
n=r-\ell+1,
\qquad
N_h=\max(n-h,0).
\tag{3}
\]

The keys in each buffer are strictly consecutive. \(P\) begins at \(\ell\),
\(Q\) ends at \(r\), and their values agree where the buffers overlap. An
empty \(B_h\) uses the canonical representation \((0,0,0,0)\). Means and
co-moments must be finite apart from a separately documented overflow policy.

These invariants make a state self-validating enough to prevent a gap from
being mistaken for adjacency at a chunk boundary.

## 4. Keyed addition

To append \((k,z)\) to a nonempty state, require

\[
k=r+1.
\tag{4}
\]

Update \(U\) by merging it with \((1,z,0)\). For every
\(1\le h\le\min(L,n)\), the only new lag-\(h\) pair is

\[
(x_{k-h},z),
\]

whose first value is available in \(Q\). Merge its singleton bivariate moment
into \(B_h\) with (2). For \(h>n\), \(B_h\) remains canonically empty. Finally,

\[
P'=\operatorname{first}_L(P\mathbin\Vert[(k,z)]),
\qquad
Q'=\operatorname{last}_L(Q\mathbin\Vert[(k,z)]),
\]

and set \(r'=k,n'=n+1\). Adding to an empty state creates the interval
\([k,k]\), \(U=(1,z,0)\), empty lag summaries, and singleton buffers.

A prepend operation is the mirror image, but an implementation needs only one
primitive: prepend can be expressed as a canonical merge with a singleton.

## 5. Validated canonical merge

Before any arithmetic, validate both operands against the invariants in
Section 3 and require equal \(L\). Empty operands are identities. For two
nonempty states, exactly one of the following must hold:

\[
r_A+1=\ell_B
\qquad\text{or}\qquad
r_B+1=\ell_A.
\tag{5}
\]

If neither holds, reject the merge: the ranges overlap, duplicate a key, or
contain a gap. If the second relation holds, swap the operands. Hence all
subsequent equations use the canonical left state \(A\) and right state \(B\),
independently of call-site argument order.

Merge the overall moments using (1). The output range is
\([\ell_A,r_B]\), with \(n=n_A+n_B\), and

\[
P=\operatorname{first}_L(P_A\mathbin\Vert P_B),
\qquad
Q=\operatorname{last}_L(Q_A\mathbin\Vert Q_B).
\tag{6}
\]

For each \(h\), the cross-boundary pairs have earlier key in \(A\) and later
key in \(B\):

\[
\mathcal K_h(A,B)
=\{(x_k,x_{k+h}):
\max(\ell_A,\ell_B-h)\le k\le\min(r_A,r_B-h)\}.
\tag{7}
\]

Because the ranges are adjacent and \(h\le L\), all values in (7) are present
in \(Q_A\) and \(P_B\). Build its bivariate summary \(K_h\) by folding the
pairs in increasing \(k\), then define

\[
B_h=\operatorname{bimerge}
\left(
  \operatorname{bimerge}(B_{h,A},K_h),
  B_{h,B}
\right).
\tag{8}
\]

This left--boundary--right order is canonical and gives reproducible behavior
for a fixed partition and merge tree. After the merge, recheck (3), buffer
endpoints, and the output range. In particular, the expected pair count is

\[
N_h=N_{h,A}+|\mathcal K_h|+N_{h,B}=\max(n_A+n_B-h,0).
\tag{9}
\]

## 6. Correctness and associativity

For every lag \(h\), the pair set of an adjacent concatenation is the disjoint
union

\[
\mathcal P_h(A\Vert B)
=\mathcal P_h(A)\;\dot\cup\;\mathcal K_h(A,B)\;\dot\cup\;\mathcal P_h(B).
\tag{10}
\]

Equations (1) and (2) are exact formulas for the centered moments of a disjoint
union. Equations (6)--(8) therefore produce exactly the defining state of the
union interval:

\[
\operatorname{merge}(S_L(A),S_L(B))=S_L(A\Vert B).
\tag{11}
\]

For three consecutive intervals, both legal parenthesizations consequently
equal the state of their ordered union:

\[
\operatorname{merge}(\operatorname{merge}(S(A),S(B)),S(C))
=S(A\Vert B\Vert C)
=\operatorname{merge}(S(A),\operatorname{merge}(S(B),S(C))).
\tag{12}
\]

Thus the partial operation is associative in exact arithmetic whenever its
range preconditions are satisfied. A reducer may combine adjacent blocks in
any tree, but may not combine nonadjacent blocks merely because they are
disjoint. Canonical orientation makes `merge(A,B)` and `merge(B,A)` return the
same ordered union when the two ranges are adjacent; it does not erase time
order from the represented sequence.

## 7. Finalization: ACF and Ljung--Box

For \(1\le h\le H=\min(L,n-1)\), let

\[
B_h=(N_h,a_h,b_h,C_h),\qquad N_h=n-h.
\]

The lag numerator centered at the overall mean is

\[
G_h=\sum_{k=\ell}^{r-h}(x_k-\mu)(x_{k+h}-\mu).
\]

Expanding around the two pair-marginal means gives the stable conversion

\[
G_h=C_h+N_h(a_h-\mu)(b_h-\mu).
\tag{13}
\]

The cross terms vanish because deviations from \(a_h\) and \(b_h\) sum to
zero. An equivalent endpoint formula avoids subtracting separately accumulated
pair means. Define

\[
E_h^- = \sum_{k=\ell}^{\ell+h-1}(x_k-\mu),
\qquad
E_h^+ = \sum_{k=r-h+1}^{r}(x_k-\mu).
\]

Since the left marginal omits the final \(h\) values and the right marginal
omits the initial \(h\) values,

\[
a_h-\mu=-\frac{E_h^+}{n-h},
\qquad
b_h-\mu=-\frac{E_h^-}{n-h},
\]

so

\[
G_h=C_h+\frac{E_h^-E_h^+}{n-h}.
\tag{14}
\]

Both endpoint sums come from \(P,Q\). Equation (14) is often preferable when
the pair means are very close to a large common level.

For \(M_2>0\), the conventional sample autocorrelation is

\[
\rho_h=\frac{G_h}{M_2}.
\tag{15}
\]

This is equivalent to dividing both lagged and lag-zero autocovariances by
\(n\). It is not the alternative convention that divides \(G_h\) by \(n-h\).

For \(1\le m\le H\), the Ljung--Box statistic is

\[
Q_{\mathrm{LB}}(m)
=n(n+2)\sum_{h=1}^{m}\frac{\rho_h^2}{n-h}.
\tag{16}
\]

The usual asymptotic null reference is \(\chi^2_\nu\), with \(\nu=m\) for an
unadjusted series and commonly \(\nu=m-p-q\) for residuals from an
ARMA\((p,q)\) fit. Finalization must require \(\nu>0\).

If callers explicitly need raw quantities, they can be reconstructed as

\[
\sum_k x_k=n\mu,
\qquad
\sum_k x_k^2=M_2+n\mu^2,
\qquad
\sum_{k=\ell}^{r-h}x_kx_{k+h}=C_h+N_h a_hb_h.
\tag{17}
\]

These reconstructions are intentionally not used for ACF computation because
they can recreate the cancellation that the centered state avoids.

## 8. Edge semantics

- \(L=0\) is valid and stores only the overall moment and empty buffers.
- Empty input has no mean, variance, ACF, or Ljung--Box statistic.
- A one-point input has \(M_2=0\) and no positive valid lag.
- Lags \(h\ge n\) are absent, not zero correlations.
- If \(M_2=0\), every \(\rho_h\) and the Ljung--Box statistic are undefined.
- NaN and infinity should be rejected at ingestion. Propagation is acceptable
  only if explicitly chosen as a different API contract.
- A missing key must not be compressed away. Either terminate the current
  interval and keep the series separate, or use a different missing-aware
  design with per-lag masks and counts.
- A merge across an intentional series boundary is invalid even if integer
  keys happen to be adjacent; include a series identity in the state and
  require equality when multiple logical series share a key space.
- Integer key successor checks must be overflow-safe: test the ranges before
  evaluating \(r+1\) at the maximum representable key.

## 9. Floating-point behavior

Equations (1), (2), and (13) avoid the most damaging raw-sum cancellations,
but floating arithmetic is not exactly associative. Different legal merge
trees can differ by rounding. Canonical left/right orientation does not make
all tree shapes bitwise identical.

Practical requirements are:

- use a fixed merge tree when bitwise repeatability is required;
- prefer balanced trees over long one-sided folds;
- use fused multiply-add for correction terms where available;
- use wider precision or compensated accumulation for boundary singleton
  folds and endpoint sums;
- clamp a tiny negative \(M_2\) to zero only under a documented tolerance;
  otherwise report a numerical failure;
- compare distributed results with scale-aware tolerances, not exact equality;
- detect count, key, product, and moment overflow.

If values share an extremely large offset, storing all values after subtracting
one fixed series-wide origin \(c\) improves even the mean-difference operations.
Centered moments, ACF, and Ljung--Box are translation invariant, so no
final-result correction is required. The same \(c\) must be used by every
partial state.

## 10. Complexity

The state contains \(L\) bivariate summaries and two length-\(L\) boundary
buffers, so its space cost is \(O(L)\).

- keyed singleton append: \(O(L)\) time;
- finalization of all available lags: \(O(L)\) time using cumulative endpoint
  sums;
- straightforward merge: \(O(L^2)\) time in the worst case, because lag \(h\)
  has up to \(h\) cross-boundary pairs;
- validation excluding buffer scans: \(O(L)\); including all buffer keys and
  lag counts remains \(O(L)\).

Unlike raw cross-products, centered boundary pair summaries cannot in general
be obtained by one scalar convolution alone: their means and co-moment must
also be formed. For typical diagnostic lags the simple \(O(L^2)\) merge is the
clearest reference implementation.

## 11. Reference formulas and tests

For a direct oracle, enumerate the observations in key order and compute

\[
\mu^*=\frac1n\sum_i x_i,
\qquad
M_2^*=\sum_i(x_i-\mu^*)^2,
\]

\[
a_h^*=\frac1{n-h}\sum_{i=1}^{n-h}x_i,
\qquad
b_h^*=\frac1{n-h}\sum_{i=1}^{n-h}x_{i+h},
\]

\[
C_h^*=\sum_{i=1}^{n-h}(x_i-a_h^*)(x_{i+h}-b_h^*),
\]

\[
G_h^*=\sum_{i=1}^{n-h}(x_i-\mu^*)(x_{i+h}-\mu^*),
\qquad
\rho_h^*=G_h^*/M_2^*.
\tag{18}
\]

Property tests should cover:

1. singleton folding versus (18);
2. every two-way split versus direct aggregation;
3. all legal parenthesizations of three or more consecutive chunks;
4. reversed merge arguments, which canonicalize to the same ordered result;
5. rejection of overlaps, duplicate boundary keys, gaps, different \(L\), and
   corrupted pair counts or buffers;
6. chunks shorter than \(L\), \(n=L\), \(n=L+1\), empty identities, and
   \(m=n-1\);
7. constant values, alternating signs, very large common offsets with small
   variation, and values spanning several magnitudes;
8. agreement of (13) and (14), and agreement of (16) with a direct loop.

For the exact example \((x_1,x_2,x_3)=(1,2,4)\),

\[
\mu=\frac73,
\qquad
M_2=\frac{14}{3}.
\]

At lag one,

\[
B_1=\left(2,\frac32,3,1\right),
\qquad
G_1=1+2\left(\frac32-\frac73\right)
             \left(3-\frac73\right)=-\frac19,
\]

and at lag two,

\[
B_2=(1,1,4,0),
\qquad
G_2=\left(1-\frac73\right)\left(4-\frac73\right)=-\frac{20}{9}.
\]

Therefore

\[
\rho_1=-\frac1{42},
\qquad
\rho_2=-\frac{10}{21},
\]

and

\[
Q_{\mathrm{LB}}(2)
=3(3+2)\left(\frac{\rho_1^2}{3-1}+\frac{\rho_2^2}{3-2}\right)
=\frac{1335}{392}.
\]
