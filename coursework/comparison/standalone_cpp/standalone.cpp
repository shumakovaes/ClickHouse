#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace lagdemo {

using Key = std::int64_t;
using Real = long double;

struct UniMoment {
  std::uint64_t count{};
  Real mean{};
  Real m2{};
};

UniMoment combine(UniMoment a, UniMoment b) {
  if (a.count == 0) return b;
  if (b.count == 0) return a;
  const auto count = a.count + b.count;
  if (count < a.count) throw std::overflow_error("moment count overflow");
  const Real delta = b.mean - a.mean;
  const Real weight = static_cast<Real>(b.count) / static_cast<Real>(count);
  return {count,
          a.mean + delta * weight,
          a.m2 + b.m2 + delta * delta *
              (static_cast<Real>(a.count) * static_cast<Real>(b.count) /
               static_cast<Real>(count))};
}

struct BiMoment {
  std::uint64_t count{};
  Real mean_x{};
  Real mean_y{};
  Real m2_x{};
  Real m2_y{};
  Real co{};
  Real diff2{};  // Sum (y-x)^2; useful for Durbin--Watson at lag one.
};

BiMoment pair_moment(Real x, Real y) {
  const Real d = y - x;
  return {1, x, y, 0, 0, 0, d * d};
}

BiMoment combine(BiMoment a, BiMoment b) {
  if (a.count == 0) return b;
  if (b.count == 0) return a;
  const auto count = a.count + b.count;
  if (count < a.count) throw std::overflow_error("bivariate count overflow");
  const Real dx = b.mean_x - a.mean_x;
  const Real dy = b.mean_y - a.mean_y;
  const Real bridge = static_cast<Real>(a.count) *
                      static_cast<Real>(b.count) /
                      static_cast<Real>(count);
  const Real weight = static_cast<Real>(b.count) / static_cast<Real>(count);
  return {count,
          a.mean_x + dx * weight,
          a.mean_y + dy * weight,
          a.m2_x + b.m2_x + dx * dx * bridge,
          a.m2_y + b.m2_y + dy * dy * bridge,
          a.co + b.co + dx * dy * bridge,
          a.diff2 + b.diff2};
}

struct PrefixQuadratic {
  // For local prefix sums s_j = x_1+...+x_j:
  // sum_s = sum s_j, sum_s2 = sum s_j^2, sum_js = sum j*s_j.
  Real sum_s{};
  Real sum_s2{};
  Real sum_js{};
};

struct Diagnostics {
  std::vector<Real> acf;  // acf[h-1] is rho_h.
  Real ljung_box{};
  Real durbin_watson{};
  Real ar1_intercept{};
  Real ar1_phi{};
  Real ar1_phi_no_intercept{};
  Real kpss{};
};

struct KeyValue {
  Key key{};
  Real value{};
};

class CompactState {
 public:
  explicit CompactState(std::size_t max_lag = 0)
      : max_lag_(max_lag), lag_(max_lag) {}

  std::size_t max_lag() const { return max_lag_; }
  bool empty() const { return n_ == 0; }
  std::uint64_t size() const { return n_; }
  Key first_key() const {
    if (empty()) throw std::logic_error("empty state has no first key");
    return lo_;
  }
  Key last_key() const {
    if (empty()) throw std::logic_error("empty state has no last key");
    return hi_;
  }

  void append(Key key, Real value) {
    if (!std::isfinite(value)) throw std::invalid_argument("non-finite value");
    if (empty()) {
      lo_ = hi_ = key;
      n_ = 1;
      overall_ = {1, value, 0};
      origin_ = value;
      shifted_sum_ = 0;
      if (max_lag_ != 0) {
        prefix_.push_back({key, value});
        suffix_.push_back({key, value});
      }
      prefix_quad_ = {};
      validate();
      return;
    }
    if (hi_ == std::numeric_limits<Key>::max() || key != hi_ + 1)
      throw std::invalid_argument("append key is not the immediate successor");

    for (std::size_t h = 1; h <= max_lag_ && h <= n_; ++h) {
      const Real prior = suffix_[suffix_.size() - h].value;
      lag_[h - 1] = combine(lag_[h - 1], pair_moment(prior, value));
    }

    const Real shifted_value = value - origin_;
    const Real new_prefix_sum = shifted_sum_ + shifted_value;
    overall_ = combine(overall_, UniMoment{1, value, 0});
    ++n_;
    hi_ = key;
    shifted_sum_ = new_prefix_sum;
    prefix_quad_.sum_s += new_prefix_sum;
    prefix_quad_.sum_s2 += new_prefix_sum * new_prefix_sum;
    prefix_quad_.sum_js += static_cast<Real>(n_) * new_prefix_sum;

    if (max_lag_ != 0) {
      if (prefix_.size() < max_lag_) prefix_.push_back({key, value});
      suffix_.push_back({key, value});
      if (suffix_.size() > max_lag_) suffix_.erase(suffix_.begin());
    }
    validate();
  }

  static CompactState merge(CompactState lhs, CompactState rhs) {
    lhs.validate();
    rhs.validate();
    if (lhs.max_lag_ != rhs.max_lag_)
      throw std::invalid_argument("max-lag mismatch");
    if (lhs.empty()) return rhs;
    if (rhs.empty()) return lhs;

    if (adjacent(rhs, lhs)) std::swap(lhs, rhs);
    if (!adjacent(lhs, rhs))
      throw std::invalid_argument("compact ranges are not adjacent");

    CompactState out(lhs.max_lag_);
    out.lo_ = lhs.lo_;
    out.hi_ = rhs.hi_;
    out.n_ = checked_add(lhs.n_, rhs.n_);
    out.overall_ = combine(lhs.overall_, rhs.overall_);
    out.origin_ = lhs.origin_;

    out.prefix_ = lhs.prefix_;
    out.prefix_.insert(out.prefix_.end(), rhs.prefix_.begin(), rhs.prefix_.end());
    if (out.prefix_.size() > out.max_lag_) out.prefix_.resize(out.max_lag_);

    out.suffix_ = lhs.suffix_;
    out.suffix_.insert(out.suffix_.end(), rhs.suffix_.begin(), rhs.suffix_.end());
    if (out.suffix_.size() > out.max_lag_) {
      out.suffix_.erase(out.suffix_.begin(),
                        out.suffix_.end() - static_cast<std::ptrdiff_t>(out.max_lag_));
    }

    for (std::size_t h = 1; h <= out.max_lag_; ++h) {
      BiMoment boundary;
      const std::uint64_t hh = static_cast<std::uint64_t>(h);
      const std::uint64_t first_from_right = hh > rhs.n_ ? hh - rhs.n_ : 0;
      const std::uint64_t last_from_right =
          std::min<std::uint64_t>(hh - 1, lhs.n_ - 1);
      if (first_from_right <= last_from_right) {
        for (std::uint64_t offset = first_from_right;; ++offset) {
          const std::size_t left_index = lhs.suffix_.size() - 1 -
                                         static_cast<std::size_t>(offset);
          const std::size_t right_index =
              static_cast<std::size_t>(hh - offset - 1);
          boundary = combine(boundary,
                             pair_moment(lhs.suffix_[left_index].value,
                                         rhs.prefix_[right_index].value));
          if (offset == last_from_right) break;
        }
      }
      out.lag_[h - 1] = combine(combine(lhs.lag_[h - 1], boundary),
                                rhs.lag_[h - 1]);
    }

    const Real nb = static_cast<Real>(rhs.n_);
    const Real na = static_cast<Real>(lhs.n_);
    const Real j1b = nb * (nb + 1) / 2;
    const Real j2b = nb * (nb + 1) * (2 * nb + 1) / 6;
    const Real origin_delta = rhs.origin_ - lhs.origin_;
    PrefixQuadratic right_quad = rhs.prefix_quad_;
    right_quad.sum_s2 += 2 * origin_delta * right_quad.sum_js +
                         origin_delta * origin_delta * j2b;
    right_quad.sum_s += origin_delta * j1b;
    right_quad.sum_js += origin_delta * j2b;
    const Real right_shifted_sum = rhs.shifted_sum_ + nb * origin_delta;
    const Real sum_a = lhs.shifted_sum_;
    out.shifted_sum_ = sum_a + right_shifted_sum;
    out.prefix_quad_.sum_s = lhs.prefix_quad_.sum_s +
                             nb * sum_a + right_quad.sum_s;
    out.prefix_quad_.sum_s2 = lhs.prefix_quad_.sum_s2 +
                              right_quad.sum_s2 +
                              2 * sum_a * right_quad.sum_s +
                              nb * sum_a * sum_a;
    out.prefix_quad_.sum_js = lhs.prefix_quad_.sum_js +
                              right_quad.sum_js +
                              na * right_quad.sum_s +
                              sum_a * (na * nb + j1b);
    out.validate();
    return out;
  }

  Diagnostics diagnostics(std::size_t lb_lags, std::size_t kpss_bandwidth) const {
    validate();
    if (empty()) throw std::domain_error("diagnostics require observations");
    const std::size_t available =
        std::min<std::size_t>(max_lag_, static_cast<std::size_t>(n_ - 1));
    if (lb_lags == 0 || lb_lags > available)
      throw std::invalid_argument("invalid Ljung--Box lag count");
    if (kpss_bandwidth > available)
      throw std::invalid_argument("KPSS bandwidth exceeds stored lags");
    if (!(overall_.m2 > 0)) throw std::domain_error("zero centered variance");

    Diagnostics d;
    d.acf.reserve(available);
    std::vector<Real> centered_cross(available);
    Real first_endpoint_sum = 0;
    Real last_endpoint_sum = 0;
    for (std::size_t h = 1; h <= available; ++h) {
      const BiMoment& b = lag_[h - 1];
      const Real nh = static_cast<Real>(b.count);
      first_endpoint_sum += prefix_[h - 1].value - overall_.mean;
      last_endpoint_sum += suffix_[suffix_.size() - h].value - overall_.mean;
      // The left pair marginal omits the final h values and the right
      // marginal omits the initial h values. This endpoint form avoids
      // subtracting two independently rounded means near a large offset.
      const Real g = b.co + first_endpoint_sum * last_endpoint_sum / nh;
      centered_cross[h - 1] = g;
      d.acf.push_back(g / overall_.m2);
    }

    const Real rn = static_cast<Real>(n_);
    Real lb_sum = 0;
    for (std::size_t h = 1; h <= lb_lags; ++h) {
      const Real rho = d.acf[h - 1];
      lb_sum += rho * rho / (rn - static_cast<Real>(h));
    }
    d.ljung_box = rn * (rn + 2) * lb_sum;

    const Real raw_ssq = overall_.m2 + rn * overall_.mean * overall_.mean;
    if (!(raw_ssq > 0)) throw std::domain_error("zero raw sum of squares");
    d.durbin_watson = lag_[0].diff2 / raw_ssq;

    const BiMoment& ar = lag_[0];
    if (ar.count < 2 || !(ar.m2_x > 0))
      throw std::domain_error("AR(1) with intercept is unidentified");
    d.ar1_phi = ar.co / ar.m2_x;
    d.ar1_intercept = ar.mean_y - d.ar1_phi * ar.mean_x;
    const Real raw_x2 = ar.m2_x + static_cast<Real>(ar.count) *
                                      ar.mean_x * ar.mean_x;
    const Real raw_xy = ar.co + static_cast<Real>(ar.count) *
                                  ar.mean_x * ar.mean_y;
    if (!(raw_x2 > 0)) throw std::domain_error("AR(1) origin fit is unidentified");
    d.ar1_phi_no_intercept = raw_xy / raw_x2;

    Real long_run = overall_.m2;
    for (std::size_t h = 1; h <= kpss_bandwidth; ++h) {
      const Real weight = 1 - static_cast<Real>(h) /
                                  static_cast<Real>(kpss_bandwidth + 1);
      long_run += 2 * weight * centered_cross[h - 1];
    }
    long_run /= rn;
    if (!(long_run > 0)) throw std::domain_error("nonpositive KPSS long-run variance");
    const Real t2 = rn * (rn + 1) * (2 * rn + 1) / 6;
    const Real shifted_mean = overall_.mean - origin_;
    Real cumulative_residual_sq = prefix_quad_.sum_s2 -
                                  2 * shifted_mean * prefix_quad_.sum_js +
                                  shifted_mean * shifted_mean * t2;
    const Real scale = std::max<Real>(1, prefix_quad_.sum_s2);
    if (cumulative_residual_sq < 0 &&
        std::fabs(cumulative_residual_sq) <=
            64 * std::numeric_limits<Real>::epsilon() * scale) {
      cumulative_residual_sq = 0;
    }
    if (cumulative_residual_sq < 0)
      throw std::runtime_error("negative KPSS numerator from cancellation");
    d.kpss = cumulative_residual_sq / (rn * rn * long_run);
    return d;
  }

  std::string serialize() const {
    validate();
    std::ostringstream os;
    os.imbue(std::locale::classic());
    os << std::setprecision(std::numeric_limits<Real>::max_digits10);
    os << "COMPACT1 " << max_lag_ << ' ' << n_ << ' ' << lo_ << ' ' << hi_ << ' '
       << origin_ << ' ' << shifted_sum_ << ' ';
    write(os, overall_);
    write(os, prefix_quad_);
    write(os, prefix_);
    write(os, suffix_);
    os << lag_.size() << ' ';
    for (const auto& b : lag_) write(os, b);
    return os.str();
  }

  static CompactState deserialize(const std::string& text) {
    std::istringstream is(text);
    is.imbue(std::locale::classic());
    std::string tag;
    std::size_t l{};
    CompactState out;
    if (!(is >> tag >> l) || tag != "COMPACT1")
      throw std::invalid_argument("bad compact serialization tag");
    out = CompactState(l);
    if (!(is >> out.n_ >> out.lo_ >> out.hi_ >> out.origin_ >> out.shifted_sum_))
      throw std::invalid_argument("bad compact header");
    read(is, out.overall_);
    read(is, out.prefix_quad_);
    read(is, out.prefix_);
    read(is, out.suffix_);
    std::size_t lag_count{};
    if (!(is >> lag_count) || lag_count != l)
      throw std::invalid_argument("bad lag vector size");
    for (auto& b : out.lag_) read(is, b);
    is >> std::ws;
    if (!is.eof()) throw std::invalid_argument("trailing compact data");
    out.validate();
    return out;
  }

  void validate() const {
    if (lag_.size() != max_lag_) throw std::logic_error("bad lag vector size");
    if (n_ == 0) {
      if (overall_.count != 0 || !prefix_.empty() || !suffix_.empty())
        throw std::logic_error("noncanonical empty state");
      for (const auto& b : lag_)
        if (b.count != 0) throw std::logic_error("nonempty lag in empty state");
      return;
    }
    if (hi_ < lo_) throw std::logic_error("reversed key interval");
    const std::uint64_t span = static_cast<std::uint64_t>(hi_) -
                               static_cast<std::uint64_t>(lo_);
    if (span == std::numeric_limits<std::uint64_t>::max() || span + 1 != n_)
      throw std::logic_error("key interval/count mismatch");
    if (overall_.count != n_) throw std::logic_error("overall count mismatch");
    const std::size_t edge = static_cast<std::size_t>(
        std::min<std::uint64_t>(n_, static_cast<std::uint64_t>(max_lag_)));
    if (prefix_.size() != edge || suffix_.size() != edge)
      throw std::logic_error("boundary buffer size mismatch");
    validate_buffer(prefix_, lo_, true);
    validate_buffer(suffix_, hi_, false);
    for (const auto& p : prefix_) {
      for (const auto& q : suffix_) {
        if (p.key == q.key && p.value != q.value)
          throw std::logic_error("overlapping buffers disagree");
      }
    }
    for (std::size_t h = 1; h <= max_lag_; ++h) {
      const std::uint64_t expected = n_ > h ? n_ - h : 0;
      if (lag_[h - 1].count != expected)
        throw std::logic_error("lag pair count mismatch");
    }
  }

 private:
  static std::uint64_t checked_add(std::uint64_t a, std::uint64_t b) {
    const auto c = a + b;
    if (c < a) throw std::overflow_error("sample count overflow");
    return c;
  }

  static bool adjacent(const CompactState& left, const CompactState& right) {
    return left.hi_ != std::numeric_limits<Key>::max() &&
           left.hi_ + 1 == right.lo_;
  }

  static void validate_buffer(const std::vector<KeyValue>& v, Key endpoint,
                              bool is_prefix) {
    if (v.empty()) return;
    for (std::size_t i = 1; i < v.size(); ++i) {
      if (v[i - 1].key == std::numeric_limits<Key>::max() ||
          v[i].key != v[i - 1].key + 1)
        throw std::logic_error("nonconsecutive boundary buffer");
    }
    if ((is_prefix && v.front().key != endpoint) ||
        (!is_prefix && v.back().key != endpoint))
      throw std::logic_error("boundary endpoint mismatch");
  }

  static void write(std::ostream& os, const UniMoment& u) {
    os << u.count << ' ' << u.mean << ' ' << u.m2 << ' ';
  }
  static void write(std::ostream& os, const BiMoment& b) {
    os << b.count << ' ' << b.mean_x << ' ' << b.mean_y << ' '
       << b.m2_x << ' ' << b.m2_y << ' ' << b.co << ' ' << b.diff2 << ' ';
  }
  static void write(std::ostream& os, const PrefixQuadratic& p) {
    os << p.sum_s << ' ' << p.sum_s2 << ' ' << p.sum_js << ' ';
  }
  static void write(std::ostream& os, const std::vector<KeyValue>& v) {
    os << v.size() << ' ';
    for (const auto& p : v) os << p.key << ' ' << p.value << ' ';
  }
  static void read(std::istream& is, UniMoment& u) {
    if (!(is >> u.count >> u.mean >> u.m2))
      throw std::invalid_argument("bad univariate moment");
  }
  static void read(std::istream& is, BiMoment& b) {
    if (!(is >> b.count >> b.mean_x >> b.mean_y >> b.m2_x >> b.m2_y >>
          b.co >> b.diff2))
      throw std::invalid_argument("bad bivariate moment");
  }
  static void read(std::istream& is, PrefixQuadratic& p) {
    if (!(is >> p.sum_s >> p.sum_s2 >> p.sum_js))
      throw std::invalid_argument("bad prefix quadratic");
  }
  static void read(std::istream& is, std::vector<KeyValue>& v) {
    std::size_t count{};
    if (!(is >> count)) throw std::invalid_argument("bad buffer size");
    v.resize(count);
    for (auto& p : v)
      if (!(is >> p.key >> p.value)) throw std::invalid_argument("bad buffer");
  }

  std::size_t max_lag_{};
  Key lo_{};
  Key hi_{};
  std::uint64_t n_{};
  UniMoment overall_{};
  Real origin_{};
  Real shifted_sum_{};
  std::vector<BiMoment> lag_;
  std::vector<KeyValue> prefix_;
  std::vector<KeyValue> suffix_;
  PrefixQuadratic prefix_quad_{};
};

class FullSampleState {
 public:
  explicit FullSampleState(std::size_t max_lag = 0) : max_lag_(max_lag) {}

  void insert(Key key, Real value) {
    if (!std::isfinite(value)) throw std::invalid_argument("non-finite value");
    if (!samples_.emplace(key, value).second)
      throw std::invalid_argument("duplicate key");
  }

  static FullSampleState merge(FullSampleState a, const FullSampleState& b) {
    if (a.max_lag_ != b.max_lag_)
      throw std::invalid_argument("max-lag mismatch");
    for (const auto& [key, value] : b.samples_)
      if (!a.samples_.emplace(key, value).second)
        throw std::invalid_argument("duplicate key during full-state merge");
    return a;
  }

  Diagnostics diagnostics(std::size_t lb_lags, std::size_t bandwidth) const {
    std::vector<Real> x;
    x.reserve(samples_.size());
    if (!samples_.empty()) {
      auto it = samples_.begin();
      Key prior = it->first;
      x.push_back(it->second);
      for (++it; it != samples_.end(); ++it) {
        if (prior == std::numeric_limits<Key>::max() || it->first != prior + 1)
          throw std::invalid_argument("full sample is not dense");
        prior = it->first;
        x.push_back(it->second);
      }
    }
    return direct_diagnostics(x, max_lag_, lb_lags, bandwidth);
  }

  std::string serialize() const {
    std::ostringstream os;
    os.imbue(std::locale::classic());
    os << std::setprecision(std::numeric_limits<Real>::max_digits10);
    os << "FULL1 " << max_lag_ << ' ' << samples_.size() << ' ';
    for (const auto& [key, value] : samples_) os << key << ' ' << value << ' ';
    return os.str();
  }

  static FullSampleState deserialize(const std::string& text) {
    std::istringstream is(text);
    is.imbue(std::locale::classic());
    std::string tag;
    std::size_t l{}, count{};
    if (!(is >> tag >> l >> count) || tag != "FULL1")
      throw std::invalid_argument("bad full serialization header");
    FullSampleState out(l);
    for (std::size_t i = 0; i < count; ++i) {
      Key key{};
      Real value{};
      if (!(is >> key >> value)) throw std::invalid_argument("bad full sample");
      out.insert(key, value);
    }
    is >> std::ws;
    if (!is.eof()) throw std::invalid_argument("trailing full data");
    return out;
  }

  static Diagnostics direct_diagnostics(const std::vector<Real>& x,
                                        std::size_t max_lag,
                                        std::size_t lb_lags,
                                        std::size_t bandwidth) {
    if (x.empty()) throw std::domain_error("diagnostics require observations");
    const std::size_t n = x.size();
    const std::size_t available = std::min(max_lag, n - 1);
    if (lb_lags == 0 || lb_lags > available)
      throw std::invalid_argument("invalid Ljung--Box lag count");
    if (bandwidth > available)
      throw std::invalid_argument("KPSS bandwidth exceeds stored lags");

    UniMoment all;
    for (Real value : x) all = combine(all, UniMoment{1, value, 0});
    if (!(all.m2 > 0)) throw std::domain_error("zero centered variance");
    Diagnostics d;
    std::vector<Real> g(available);
    for (std::size_t h = 1; h <= available; ++h) {
      Real cross = 0;
      for (std::size_t i = 0; i + h < n; ++i)
        cross += (x[i] - all.mean) * (x[i + h] - all.mean);
      g[h - 1] = cross;
      d.acf.push_back(g[h - 1] / all.m2);
    }
    const Real rn = static_cast<Real>(n);
    Real lb = 0;
    for (std::size_t h = 1; h <= lb_lags; ++h)
      lb += d.acf[h - 1] * d.acf[h - 1] /
            (rn - static_cast<Real>(h));
    d.ljung_box = rn * (rn + 2) * lb;

    Real raw_ssq = 0;
    Real diff2 = 0;
    for (std::size_t i = 0; i < n; ++i) {
      raw_ssq += x[i] * x[i];
      if (i != 0) {
        const Real delta = x[i] - x[i - 1];
        diff2 += delta * delta;
      }
    }
    if (!(raw_ssq > 0)) throw std::domain_error("zero raw sum of squares");
    d.durbin_watson = diff2 / raw_ssq;

    BiMoment ar;
    for (std::size_t i = 0; i + 1 < n; ++i)
      ar = combine(ar, pair_moment(x[i], x[i + 1]));
    if (ar.count < 2 || !(ar.m2_x > 0))
      throw std::domain_error("AR(1) with intercept is unidentified");
    d.ar1_phi = ar.co / ar.m2_x;
    d.ar1_intercept = ar.mean_y - d.ar1_phi * ar.mean_x;
    Real ar_x2 = 0;
    Real ar_xy = 0;
    for (std::size_t i = 0; i + 1 < n; ++i) {
      ar_x2 += x[i] * x[i];
      ar_xy += x[i] * x[i + 1];
    }
    d.ar1_phi_no_intercept = ar_xy / ar_x2;

    Real cumulative = 0;
    Real numerator = 0;
    for (Real value : x) {
      cumulative += value - all.mean;
      numerator += cumulative * cumulative;
    }
    Real long_run = all.m2;
    for (std::size_t h = 1; h <= bandwidth; ++h) {
      const Real weight = 1 - static_cast<Real>(h) /
                                  static_cast<Real>(bandwidth + 1);
      long_run += 2 * weight * g[h - 1];
    }
    long_run /= rn;
    if (!(long_run > 0)) throw std::domain_error("nonpositive KPSS long-run variance");
    d.kpss = numerator / (rn * rn * long_run);
    return d;
  }

 private:
  std::size_t max_lag_{};
  std::map<Key, Real> samples_;
};

struct TestRunner {
  int checks{};

  void require(bool condition, const std::string& message) {
    ++checks;
    if (!condition) throw std::runtime_error("test failure: " + message);
  }

  void near(Real actual, Real expected, Real tolerance,
            const std::string& message) {
    const Real scale = std::max<Real>({1, std::fabs(actual), std::fabs(expected)});
    require(std::fabs(actual - expected) <= tolerance * scale,
            message + ": actual=" + printable(actual) +
                " expected=" + printable(expected));
  }

  template <class Function>
  void throws(Function&& fn, const std::string& message) {
    ++checks;
    try {
      fn();
    } catch (const std::exception&) {
      return;
    }
    throw std::runtime_error("test failure: expected exception: " + message);
  }

  static std::string printable(Real x) {
    std::ostringstream os;
    os << std::setprecision(20) << x;
    return os.str();
  }
};

void compare(TestRunner& t, const Diagnostics& a, const Diagnostics& b,
             Real tol, const std::string& label) {
  t.require(a.acf.size() == b.acf.size(), label + " ACF size");
  for (std::size_t i = 0; i < a.acf.size(); ++i)
    t.near(a.acf[i], b.acf[i], tol, label + " ACF");
  t.near(a.ljung_box, b.ljung_box, tol, label + " Ljung--Box");
  t.near(a.durbin_watson, b.durbin_watson, tol, label + " DW");
  t.near(a.ar1_intercept, b.ar1_intercept, tol, label + " AR1 intercept");
  t.near(a.ar1_phi, b.ar1_phi, tol, label + " AR1 phi");
  t.near(a.ar1_phi_no_intercept, b.ar1_phi_no_intercept, tol,
         label + " AR1 phi through origin");
  t.near(a.kpss, b.kpss, tol, label + " KPSS");
}

CompactState compact_chunk(const std::vector<Real>& x, std::size_t begin,
                           std::size_t end, Key first_key, std::size_t l) {
  CompactState state(l);
  for (std::size_t i = begin; i < end; ++i)
    state.append(first_key + static_cast<Key>(i), x[i]);
  return state;
}

void run_tests() {
  TestRunner t;
  constexpr Real tol = 2e-15L;

  {
    const std::vector<Real> x{1, 2, 4};
    CompactState c = compact_chunk(x, 0, x.size(), 1, 2);
    FullSampleState f(2);
    for (std::size_t i = 0; i < x.size(); ++i) f.insert(static_cast<Key>(i + 1), x[i]);
    const Diagnostics cd = c.diagnostics(2, 1);
    const Diagnostics fd = f.diagnostics(2, 1);
    compare(t, cd, fd, tol, "exact example");
    t.near(cd.acf[0], -1.0L / 42, tol, "rho1 exact");
    t.near(cd.acf[1], -10.0L / 21, tol, "rho2 exact");
    t.near(cd.ljung_box, 1335.0L / 392, tol, "Ljung--Box exact");
    t.near(cd.durbin_watson, 5.0L / 21, tol, "DW exact");
    t.near(cd.ar1_phi, 2, tol, "AR1 phi exact");
    t.near(cd.ar1_intercept, 0, tol, "AR1 intercept exact");
    t.near(cd.kpss, 1.0L / 3, tol, "KPSS exact");
  }

  const std::vector<Real> data{
      1000000000.125L, 1000000001.5L, 999999999.75L, 1000000003.0L,
      1000000002.25L, 1000000005.5L, 1000000004.0L, 1000000007.125L,
      1000000006.75L, 1000000010.0L, 1000000008.5L, 1000000011.25L};
  constexpr Key base = 900;
  constexpr std::size_t l = 5;
  const Diagnostics oracle = FullSampleState::direct_diagnostics(data, l, 4, 3);

  {
    CompactState folded(l);
    FullSampleState full(l);
    for (std::size_t i = 0; i < data.size(); ++i) {
      folded.append(base + static_cast<Key>(i), data[i]);
      full.insert(base + static_cast<Key>(i), data[i]);
    }
    compare(t, folded.diagnostics(4, 3), oracle, 1e-10L, "singleton fold");
    compare(t, full.diagnostics(4, 3), oracle, tol, "full direct");

    CompactState cr = CompactState::deserialize(folded.serialize());
    FullSampleState fr = FullSampleState::deserialize(full.serialize());
    compare(t, cr.diagnostics(4, 3), folded.diagnostics(4, 3), tol,
            "compact roundtrip");
    compare(t, fr.diagnostics(4, 3), full.diagnostics(4, 3), tol,
            "full roundtrip");
  }

  std::mt19937_64 rng(0xC0FFEEULL);
  for (int trial = 0; trial < 100; ++trial) {
    std::vector<CompactState> blocks;
    for (std::size_t i = 0; i < data.size(); ++i)
      blocks.push_back(compact_chunk(data, i, i + 1, base, l));
    while (blocks.size() > 1) {
      const std::size_t i = static_cast<std::size_t>(rng() % (blocks.size() - 1));
      CompactState merged = (rng() & 1)
          ? CompactState::merge(blocks[i], blocks[i + 1])
          : CompactState::merge(blocks[i + 1], blocks[i]);
      blocks[i] = std::move(merged);
      blocks.erase(blocks.begin() + static_cast<std::ptrdiff_t>(i + 1));
    }
    compare(t, blocks.front().diagnostics(4, 3), oracle, 1e-10L,
            "random adjacent compact tree");
  }

  for (int trial = 0; trial < 40; ++trial) {
    std::vector<FullSampleState> blocks;
    for (std::size_t i = 0; i < data.size(); ++i) {
      FullSampleState one(l);
      one.insert(base + static_cast<Key>(i), data[i]);
      blocks.push_back(std::move(one));
    }
    while (blocks.size() > 1) {
      std::size_t i = static_cast<std::size_t>(rng() % blocks.size());
      std::size_t j = static_cast<std::size_t>(rng() % (blocks.size() - 1));
      if (j >= i) ++j;
      FullSampleState merged = (rng() & 1)
          ? FullSampleState::merge(blocks[i], blocks[j])
          : FullSampleState::merge(blocks[j], blocks[i]);
      if (i > j) std::swap(i, j);
      blocks.erase(blocks.begin() + static_cast<std::ptrdiff_t>(j));
      blocks.erase(blocks.begin() + static_cast<std::ptrdiff_t>(i));
      blocks.push_back(std::move(merged));
    }
    compare(t, blocks.front().diagnostics(4, 3), oracle, tol,
            "arbitrary full-state tree");
  }

  {
    CompactState left = compact_chunk(data, 0, 5, base, l);
    CompactState right = compact_chunk(data, 5, data.size(), base, l);
    const auto canonical = CompactState::merge(right, left);
    compare(t, canonical.diagnostics(4, 3), oracle, 1e-10L,
            "reversed canonical compact merge");

    CompactState gap_a(l), gap_b(l);
    gap_a.append(10, 1);
    gap_b.append(12, 2);
    t.throws([&] { (void)CompactState::merge(gap_a, gap_b); }, "compact gap");
    CompactState overlap(l), overlap2(l);
    overlap.append(20, 1);
    overlap.append(21, 2);
    overlap2.append(21, 3);
    t.throws([&] { (void)CompactState::merge(overlap, overlap2); },
             "compact overlap");
    t.throws([&] { gap_a.append(10, 2); }, "compact duplicate append");
    CompactState other_lag(l + 1);
    other_lag.append(11, 2);
    t.throws([&] { (void)CompactState::merge(gap_a, other_lag); },
             "compact max-lag mismatch");
  }

  {
    FullSampleState a(l), b(l);
    a.insert(1, 1);
    t.throws([&] { a.insert(1, 2); }, "full duplicate insert");
    b.insert(1, 3);
    t.throws([&] { (void)FullSampleState::merge(a, b); },
             "full duplicate merge");
    FullSampleState sparse(l);
    sparse.insert(1, 1);
    sparse.insert(3, 2);
    t.throws([&] { (void)sparse.diagnostics(1, 0); }, "full sparse finalize");
    t.throws([&] { (void)FullSampleState::deserialize("FULL1 2 2 1 3 1 4"); },
             "duplicate serialized key");
  }

  std::cout << "PASS: " << t.checks << " checks\n";
  std::cout << "Covered: ACF, Ljung-Box, Durbin-Watson, AR(1), KPSS, "
               "random merge trees, key validation, duplicates, round-trips\n";
}

}  // namespace lagdemo

int main() {
  try {
    lagdemo::run_tests();
    return 0;
  } catch (const std::exception& e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
