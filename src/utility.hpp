#ifndef VG_UTILITY_HPP_INCLUDED
#define VG_UTILITY_HPP_INCLUDED

#include <string>
#include <vector>
#include <sstream>
#include <omp.h>
#include <signal.h>
#include <cstring>
#include <algorithm>
#include <numeric>
#include <cmath>
#include <unordered_set>
#include <random>
#include <type_traits>
#include <regex>
#include <signal.h>
#include <unistd.h>
#include <vg/vg.pb.h>
#include "types.hpp"
#include "sha1.hpp"
#include "Variant.h"

namespace vg {

using namespace std;

char reverse_complement(const char& c);
string reverse_complement(const string& seq);
void reverse_complement_in_place(string& seq);
/// Return True if the given string is entirely Ns of either case, and false
/// otherwise.
bool is_all_n(const string& seq);
/// Return the number of threads that OMP will produce for a parallel section.
/// TODO: Assumes that this is the same for every parallel section.
int get_thread_count(void);
string wrap_text(const string& str, size_t width);
bool is_number(const string& s);

// split a string on any character found in the string of delimiters (delims)
std::vector<std::string>& split_delims(const std::string &s, const std::string& delims, std::vector<std::string> &elems);
std::vector<std::string> split_delims(const std::string &s, const std::string& delims);

const std::string sha1sum(const std::string& data);
const std::string sha1head(const std::string& data, size_t head);

bool allATGC(const string& s);
bool allATGCN(const string& s);
string nonATGCNtoN(const string& s);
// Convert ASCII-encoded DNA to upper case
string toUppercase(const string& s);
double median(std::vector<int> &v);
double stdev(const std::vector<double>& v);
// Online mean-variance computation with wellfords algorithm (pass 0's to 1st 3 params to start)
void wellford_update(size_t& count, double& mean, double& M2, double new_val);
pair<double, double> wellford_mean_var(size_t count, double mean, double M2, bool sample_variance = false);

// write a fasta sqeuence
void write_fasta_sequence(const std::string& name, const std::string& sequence, ostream& os, size_t width=80);

template<typename T>
double stdev(const T& v) {
    double sum = std::accumulate(v.begin(), v.end(), 0.0);
    double mean = sum / v.size();
    std::vector<double> diff(v.size());
    std::transform(v.begin(), v.end(), diff.begin(), [mean](double x) { return x - mean; });
    double sq_sum = std::inner_product(diff.begin(), diff.end(), diff.begin(), 0.0);
    return std::sqrt(sq_sum / v.size());
}

// Φ is the normal cumulative distribution function
// https://en.wikipedia.org/wiki/Cumulative_distribution_function
double phi(double x1, double x2);
    
/// Inverse CDF of a standard normal distribution. Must have 0 < quantile < 1.
double normal_inverse_cdf(double quantile);

/*
 * Return the log of the sum of two log-transformed values without taking them
 * out of log space.
 */
inline double add_log(double log_x, double log_y) {
    return log_x > log_y ? log_x + log(1.0 + exp(log_y - log_x)) : log_y + log(1.0 + exp(log_x - log_y));
}
    
/*
 * Return the log of the difference of two log-transformed values without taking
 * them out of log space.
 */
inline double subtract_log(double log_x, double log_y) {
    return log_x + log(1.0 - exp(log_y - log_x));
}
 
/**
 * Convert a number ln to the same number log 10.
 */   
inline double ln_to_log10(double ln) {
    return ln / log(10);
}

/**
 * Convert a number log 10 to the same number ln.
 */   
inline double log10_to_ln(double l10) {
    return l10 * log(10);
}
    
// Convert a probability to a natural log probability.
inline double prob_to_logprob(double prob) {
    return log(prob);
}
// Convert natural log probability to a probability
inline double logprob_to_prob(double logprob) {
    return exp(logprob);
}
// Add two probabilities (expressed as logprobs) together and return the result
// as a logprob.
inline double logprob_add(double logprob1, double logprob2) {
    // Pull out the larger one to avoid underflows
    double pulled_out = max(logprob1, logprob2);
    return pulled_out + prob_to_logprob(logprob_to_prob(logprob1 - pulled_out) + logprob_to_prob(logprob2 - pulled_out));
}
// Invert a logprob, and get the probability of its opposite.
inline double logprob_invert(double logprob) {
    return prob_to_logprob(1.0 - logprob_to_prob(logprob));
}

// Convert integer Phred quality score to probability of wrongness.
inline double phred_to_prob(int phred) {
    return pow(10, -((double)phred) / 10);
}

// Convert probability of wrongness to integer Phred quality score.
inline double prob_to_phred(double prob) {
    return -10.0 * log10(prob);
}

// Convert a Phred quality score directly to a natural log probability of wrongness.
inline double phred_to_logprob(int phred) {
    return (-((double)phred) / 10) / log10(exp(1.0));
}

// Convert a natural log probability of wrongness directly to a Phred quality score.
inline double logprob_to_phred(double logprob ) {
    return -10.0 * logprob * log10(exp(1.0));
}

// Take the geometric mean of two logprobs
inline double logprob_geometric_mean(double lnprob1, double lnprob2) {
    return log(sqrt(exp(lnprob1 + lnprob2)));
}

// Same thing in phred
inline double phred_geometric_mean(double phred1, double phred2) {
    return prob_to_phred(sqrt(phred_to_prob(phred1 + phred2)));
}

// normal pdf, from http://stackoverflow.com/a/10848293/238609
template <typename T>
T normal_pdf(T x, T m, T s)
{
    static const T inv_sqrt_2pi = 0.3989422804014327;
    T a = (x - m) / s;

    return inv_sqrt_2pi / s * std::exp(-T(0.5) * a * a);
}

template<typename T, typename V>
set<T> map_keys_to_set(const map<T, V>& m) {
    set<T> r;
    for (auto p : m) r.insert(p.first);
    return r;
}

// pairwise maximum
template<typename T>
vector<T> pmax(const std::vector<T>& a, const std::vector<T>& b) {
    std::vector<T> c;
    assert(a.size() == b.size());
    c.reserve(a.size());
    std::transform(a.begin(), a.end(), b.begin(),
                   std::back_inserter(c),
                   [](T a, T b) { return std::max<T>(a, b); });
    return c;
}

// maximum of all vectors
template<typename T>
vector<T> vpmax(const std::vector<std::vector<T>>& vv) {
    std::vector<T> c;
    if (vv.empty()) return c;
    c = vv.front();
    typename std::vector<std::vector<T> >::const_iterator v = vv.begin();
    ++v; // skip the first element
    for ( ; v != vv.end(); ++v) {
        c = pmax(c, *v);
    }
    return c;
}

/**
 * Compute the sum of the values in a collection. Values must be default-
 * constructable (like numbers are).
 */
template<typename Collection>
typename Collection::value_type sum(const Collection& collection) {

    // Set up an alias
    using Item = typename Collection::value_type;

    // Make a new zero-valued item to hold the sum
    auto total = Item();
    for(auto& to_sum : collection) {
        total += to_sum;
    }

    return total;

}

/**
 * Compute the sum of the values in a collection, where the values are log
 * probabilities and the result is the log of the total probability. Items must
 * be convertible to/from doubles for math.
 */
template<typename Collection>
typename Collection::value_type logprob_sum(const Collection& collection) {

    // Set up an alias
    using Item = typename Collection::value_type;

    // Pull out the minimum value
    auto min_iterator = min_element(begin(collection), end(collection));

    if(min_iterator == end(collection)) {
        // Nothing there, p = 0
        return Item(prob_to_logprob(0));
    }

    auto check_iterator = begin(collection);
    ++check_iterator;
    if(check_iterator == end(collection)) {
        // We only have a single element anyway. We don't want to subtract it
        // out because we'll get 0s.
        return *min_iterator;
    }

    // Pull this much out of every logprob.
    Item pulled_out = *min_iterator;

    if(logprob_to_prob(pulled_out) == 0) {
        // Can't divide by 0!
        // TODO: fix this in selection
        pulled_out = prob_to_logprob(1);
    }

    Item total(0);
    for(auto& to_add : collection) {
        // Sum up all the scaled probabilities.
        total += logprob_to_prob(to_add - pulled_out);
    }

    // Re-log and re-scale
    return pulled_out + prob_to_logprob(total);
}

/**
 * Temporary files. Create with create() and remove with remove(). All
 * temporary files will be deleted when the program exits normally or with
 * std::exit(). The files will be created in a directory determined from
 * environment variables, though this can be overridden with set_dir().
 * The interface is thread-safe.
 */
namespace temp_file {

    /// Create a temporary file starting with the given base name
    string create(const string& base);

    /// Create a temporary file
    string create();

    /// Remove a temporary file
    void remove(const string& filename);

    /// Set a temp dir, overriding system defaults and environment variables.
    void set_dir(const string& new_temp_dir);

    /// Get the current temp dir
    string get_dir();

} // namespace temp_file

// Code to detect if a variant lacks an ID and give it a unique but repeatable
// one.
string get_or_make_variant_id(const vcflib::Variant& variant);
string make_variant_id(const vcflib::Variant& variant);

// TODO: move these to genotypekit on a VCF emitter?

/**
 * Create the reference allele for an empty vcflib Variant, since apaprently
 * there's no method for that already. Must be called before any alt alleles are
 * added.
 */
void create_ref_allele(vcflib::Variant& variant, const std::string& allele);

/**
 * Add a new alt allele to a vcflib Variant, since apaprently there's no method
 * for that already.
 *
 * If that allele already exists in the variant, does not add it again.
 *
 * Retuerns the allele number (0, 1, 2, etc.) corresponding to the given allele
 * string in the given variant. 
 */
int add_alt_allele(vcflib::Variant& variant, const std::string& allele);

/**
 * We have a transforming map function that we can chain.
 */ 
template <template <class T, class A = std::allocator<T>> class Container, typename Input, typename Output>
Container<Output> map_over(const Container<Input>& in, const std::function<Output(const Input&)>& lambda) {
    Container<Output> to_return;
    for (const Input& item : in) {
        to_return.push_back(lambda(item));
    }
    return to_return;
}

/**
 * We have a wrapper of that to turn a container reference into a container of pointers.
 */
template <template <class T, class A = std::allocator<T>> class Container, typename Item>
Container<const Item*> pointerfy(const Container<Item>& in) {
    return map_over<Container, Item, const Item*>(in, [](const Item& item) -> const Item* {
        return &item;
    });
}

// Simple little tree
template<typename T>
struct TreeNode {
    T v;
    vector<TreeNode<T>*> children;
    TreeNode<T>* parent;
    TreeNode() : parent(0) {}
    ~TreeNode() { for (auto c : children) { delete c; } }
    void for_each_preorder(function<void(TreeNode<T>*)> lambda) {
        lambda(this);
        for (auto c : children) {
            c->for_each_preorder(lambda);
        }
    }
    void for_each_postorder(function<void(TreeNode<T>*)> lambda) {
        for (auto c : children) {
            c->for_each_postorder(lambda);
        }
        lambda(this);
    }
};
    

    
template<typename T>
struct Tree {
    typedef TreeNode<T> Node;
    Node* root;
    Tree(Node* r = 0) : root(r) { }
    ~Tree() { delete root; }
    void for_each_preorder(function<void(Node*)> lambda) {
        if (root) root->for_each_preorder(lambda);
    }
    void for_each_postorder(function<void(Node*)> lambda) {
       if (root) root->for_each_postorder(lambda);
    }

};

// vector containing positive integer values in [begin, end)
vector<size_t> range_vector(size_t begin, size_t end);
    
// vector containing positive integer values in [0, end)
inline vector<size_t> range_vector(size_t end) {
    return range_vector(0, end);
}

struct IncrementIter {
public:
    IncrementIter(size_t number) : current(number) {
        
    }
    
    inline IncrementIter& operator=(const IncrementIter& other) {
        current = other.current;
        return *this;
    }
    
    inline bool operator==(const IncrementIter& other) const {
        return current == other.current;
    }
    
    inline bool operator!=(const IncrementIter& other) const {
        return current != other.current;
    }
    
    inline IncrementIter operator++() {
        current++;
        return *this;
    }
    
    inline IncrementIter operator++( int ) {
        IncrementIter temp = *this;
        current++;
        return temp;
    }
    
    inline size_t operator*(){
        return current;
    }
    
private:
    size_t current;
};
    
size_t integer_power(size_t x, size_t power);

double slope(const std::vector<double>& x, const std::vector<double>& y);
double fit_zipf(const vector<double>& y);

/// Computes base^exponent in log(exponent) time
size_t integer_power(uint64_t base, uint64_t exponent);
/// Computes base^exponent mod modulus in log(exponent) time without requiring more
/// than 64 bits to represent exponentiated number
size_t modular_exponent(uint64_t base, uint64_t exponent, uint64_t modulus);

/// Returns a uniformly random DNA sequence of the given length
string random_sequence(size_t length);

/// Escape "%" to "%25"
string percent_url_encode(const string& seq);
string replace_in_string(string subject, const string& search, const string& replace);

/// Given a pair of random access iterators defining a range, deterministically
/// shuffle the contents of the range based on the given integer seed.
template<class RandomIt>
void deterministic_shuffle(RandomIt begin, RandomIt end, const uint32_t& seed) {
    // Make an RNG from the string
    minstd_rand rng(seed);
    
    // Perform Knuth shuffle algorithm using RNG
    int64_t width = end - begin;
    for (int64_t i = 1; i < width; i++) {
        std::swap(*(begin + (rng() % (i + 1))), *(begin + i));
    }
}

/// Given a pair of random access iterators defining a range, deterministically
/// shuffle the contents of the range based on the given string seed.
template<class RandomIt>
void deterministic_shuffle(RandomIt begin, RandomIt end, const string& seed) {
    // Turn the string into a 32-bit number.
    uint32_t seedNumber = 0;
    for (uint8_t byte : seed) {
        // Sum up with primes and overflow.
        // TODO: this is a bit of a bad hash function but it should be good enough.
        seedNumber = seedNumber * 13 + byte;
    }

    // Shuffle with the derived integer seed
    deterministic_shuffle(begin, end, seedNumber);
}

/// Make seeds for Alignments based on their sequences.
inline string make_shuffle_seed(const Alignment& aln) {
    return aln.sequence();
}

/// Make seeds for Alignments based on their sequences.
inline string make_shuffle_seed(const Alignment* aln) {
    return aln->sequence();
}

/// Make seeds for pairs of Alignments based on their concatenated sequences
inline string make_shuffle_seed(const pair<Alignment, Alignment>* alns) {
    return alns->first.sequence() + alns->second.sequence();
}

/// Do a deterministic shuffle with automatic seed determination.
template<class RandomIt>
void deterministic_shuffle(RandomIt begin, RandomIt end) {
    deterministic_shuffle(begin, end, make_shuffle_seed(*begin));
}

/**
 * Sort the items between the two given random-access iterators, as with std::sort.
 * Deterministically shuffle the ties, if any, at the top end, using the given seed generator function.
 */
template<class RandomIt, class Compare, class MakeSeed>
void sort_shuffling_ties(RandomIt begin, RandomIt end, Compare comp, MakeSeed seed) {
    
    // Sort everything
    std::stable_sort(begin, end, comp);
    
    // Comparison returns true if first argument must come before second, and
    // false otherwise. So the ties will be a run where the top thing doesn't
    // necessarily come before each other thing (i.e. comparison returns
    // false).
    
    // Count the ties at the top
    RandomIt ties_end = begin;
    while (ties_end != end && !comp(*begin, *ties_end)) {
        // We haven't hit the end of the list, and the top thing isn't strictly better than this thing.
        // So mark it as a tie and advance.
        ++ties_end;
    }
    
    if (begin != ties_end) {
        // Shuffle the ties.
        deterministic_shuffle(begin, ties_end, seed(*begin));
    }

}

/**
 * Sort the items between the two given random-access iterators, as with std::sort.
 * Deterministically shuffle the ties, if any, at the top end, using automatic seed determination.
 */
template<class RandomIt, class Compare>
void sort_shuffling_ties(RandomIt begin, RandomIt end, Compare comp) {
    
    // Make the seed using the pre-defined seed making approaches
    sort_shuffling_ties(begin, end, comp, [](decltype (*begin)& item) {
        return make_shuffle_seed(item);
    });

}

/// Compose the translations from two graph operations, both of which involved oriented transformations.
unordered_map<id_t, pair<id_t, bool>> overlay_node_translations(const unordered_map<id_t, pair<id_t, bool>>& over,
                                                                const unordered_map<id_t, pair<id_t, bool>>& under);

/// Compose the translations from two graph operations, the first of which involved oriented transformations.
unordered_map<id_t, pair<id_t, bool>> overlay_node_translations(const unordered_map<id_t, id_t>& over,
                                                                const unordered_map<id_t, pair<id_t, bool>>& under);

/// Compose the translations from two graph operations, the second of which involved oriented transformations.
unordered_map<id_t, pair<id_t, bool>> overlay_node_translations(const unordered_map<id_t, pair<id_t, bool>>& over,
                                                                const unordered_map<id_t, id_t>& under);

/// Compose the translations from two graph operations, neither of which involved oriented transformations.
unordered_map<id_t, id_t> overlay_node_translations(const unordered_map<id_t, id_t>& over,
                                                    const unordered_map<id_t, id_t>& under);
    

/// Return true if there's a command line argument (i.e. input file name) waiting to be processed. 
bool have_input_file(int& optind, int argc, char** argv);

/// Get a callback with an istream& to an open file if a file name argument is
/// present after the parsed options, or print an error message and exit if one
/// is not. Handles "-" as a filename as indicating standard input. The reference
/// passed is guaranteed to be valid only until the callback returns. Bumps up
/// optind to the next argument if a filename is found.
void get_input_file(int& optind, int argc, char** argv, function<void(istream&)> callback);

/// Parse out the name of an input file (i.e. the next positional argument), or
/// throw an error. File name must be nonempty, but may be "-" or may not exist.
string get_input_file_name(int& optind, int argc, char** argv);

/// Parse out the name of an output file (i.e. the next positional argument), or
/// throw an error. File name must be nonempty.
string get_output_file_name(int& optind, int argc, char** argv);

/// Get a callback with an istream& to an open file. Handles "-" as a filename as
/// indicating standard input. The reference passed is guaranteed to be valid
/// only until the callback returns.
void get_input_file(const string& file_name, function<void(istream&)> callback);

/// Parse a command-line argument string. Exits with an error if the string
/// does not contain exactly an item fo the appropriate type.
template<typename Result>
Result parse(const string& arg);

/// Parse a command-line argument C string. Exits with an error if the string
/// does not contain exactly an item fo the appropriate type.
template<typename Result>
Result parse(const char* arg);

/// Parse the appropriate type from the string to the destination value.
/// Return true if parsing is successful and false (or throw something) otherwise.
template<typename Result>
bool parse(const string& arg, Result& dest);

// Do one generic implementation for signed integers that fit in a long long.
// Cram the constraint into the type of the output parameter.
template<typename Result>
bool parse(const string& arg, typename enable_if<sizeof(Result) <= sizeof(long long) &&
    is_integral<Result>::value &&
    is_signed<Result>::value, Result>::type& dest) {
    
    // This will hold the next character after the number parsed
    size_t after;
    long long buffer = std::stoll(arg, &after);
    if (buffer > numeric_limits<Result>::max() || buffer < numeric_limits<Result>::min()) {
        // Out of range
        return false;
    }
    dest = (Result) buffer;
    return(after == arg.size());    
}

// Do another generic implementation for unsigned integers
template<typename Result>
bool parse(const string& arg, typename enable_if<sizeof(Result) <= sizeof(unsigned long long) &&
    is_integral<Result>::value &&
    !is_signed<Result>::value, Result>::type& dest) {
    
    // This will hold the next character after the number parsed
    size_t after;
    unsigned long long buffer = std::stoull(arg, &after);
    if (buffer > numeric_limits<Result>::max() || buffer < numeric_limits<Result>::min()) {
        // Out of range
        return false;
    }
    dest = (Result) buffer;
    return(after == arg.size());    
}              

// We also have an implementation for doubles (defined in the cpp)
template<>
bool parse(const string& arg, double& dest);

// And one for regular expressions
template<>
bool parse(const string& arg, std::regex& dest);

// Implement the first version in terms of the second, for any type
template<typename Result>
Result parse(const string& arg) {
    Result to_return;
    bool success;
    try {
        success = parse<Result>(arg, to_return);
    } catch(exception& e) {
        success = false;
    }
    if (success) {
        // Parsing worked
        return to_return;
    } else {
        // Parsing failed
        cerr << "error: could not parse " << typeid(to_return).name() << " from argument \"" << arg << "\"" << endl;
        exit(1);
    }
}

// Implement the C string version in terms of that
template<typename Result>
Result parse(const char* arg) {
    return parse<Result>(string(arg));
}
 
}

#endif
