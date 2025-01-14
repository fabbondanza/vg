#include "coverage_depth.hpp"
#include <bdsg/hash_graph.hpp>
#include "algorithms/subgraph.hpp"
#include <vg/io/stream.hpp>
#include "../path.hpp"

namespace vg {
namespace algorithms {

void packed_depths(const Packer& packer, const string& path_name, size_t min_coverage, ostream& out_stream) {
    const PathHandleGraph& graph = dynamic_cast<const PathHandleGraph&>(*packer.get_graph());
    path_handle_t path_handle = graph.get_path_handle(path_name);
    step_handle_t start_step = graph.path_begin(path_handle);
    step_handle_t end_step = graph.path_end(path_handle);
    Position cur_pos;
    size_t path_offset = 1;
    for (step_handle_t cur_step = start_step; cur_step != end_step; cur_step = graph.get_next_step(cur_step)) {
        handle_t cur_handle = graph.get_handle_of_step(cur_step);
        nid_t cur_id = graph.get_id(cur_handle);
        size_t cur_len = graph.get_length(cur_handle);
        cur_pos.set_node_id(cur_id);
        cur_pos.set_is_reverse(graph.get_is_reverse(cur_handle));
        for (size_t i = 0; i < cur_len; ++i) {
            cur_pos.set_offset(i);
            size_t pos_coverage = packer.coverage_at_position(packer.position_in_basis(cur_pos));
            if (pos_coverage >= min_coverage) {
                out_stream << path_name << "\t" << path_offset << "\t" << pos_coverage << "\n";
            }
            ++path_offset;
        }
    }
}

pair<double, double> packed_depth_of_bin(const Packer& packer,
                                         step_handle_t start_step, step_handle_t end_plus_one_step,
                                         size_t min_coverage, bool include_deletions) {

    const PathHandleGraph& graph = dynamic_cast<const PathHandleGraph&>(*packer.get_graph());

    // coverage of each node via deletion (that's contained in the bin)
    unordered_map<nid_t, size_t> deletion_coverages;
    if (include_deletions) {
        const VectorizableHandleGraph* vec_graph = dynamic_cast<const VectorizableHandleGraph*>(packer.get_graph());
        unordered_map<handle_t, step_handle_t> deletion_candidates;
        handle_t prev_handle;
        for (step_handle_t cur_step = start_step; cur_step != end_plus_one_step; cur_step = graph.get_next_step(cur_step)) {
            handle_t cur_handle = graph.get_handle_of_step(cur_step);
            graph.follow_edges(cur_handle, true, [&] (handle_t other) {
                    if (!deletion_candidates.empty() && other!= prev_handle && deletion_candidates.count(other)) {
                        edge_t edge = graph.edge_handle(other, cur_handle);
                        size_t edge_pos = vec_graph->edge_index(edge);
                        size_t deletion_coverage = packer.edge_coverage(edge_pos);
                        // quadratic alert.  if this is too slow, can use interval tree or something
                        for (step_handle_t del_step = graph.get_next_step(deletion_candidates[other]);
                             del_step != cur_step;
                             del_step = graph.get_next_step(del_step)) {
                            handle_t del_handle = graph.get_handle_of_step(del_step);
                            nid_t del_id = graph.get_id(del_handle);
                            if (!deletion_coverages.count(del_id)) {
                                deletion_coverages[del_id] = deletion_coverage;
                            } else {
                                deletion_coverages[del_id] += deletion_coverage;
                            }
                        }
                    }
                });
            prev_handle = cur_handle;
            deletion_candidates[cur_handle] = cur_step;
        }
    }

    // compute the mean and variance of our base coverage across the bin
    size_t bin_length = 0;
    double mean = 0.0;
    double M2 = 0.0;

    for (step_handle_t cur_step = start_step; cur_step != end_plus_one_step; cur_step = graph.get_next_step(cur_step)) {
        handle_t cur_handle = graph.get_handle_of_step(cur_step);
        nid_t cur_id = graph.get_id(cur_handle);
        size_t cur_len = graph.get_length(cur_handle);
        size_t del_coverage = !include_deletions or !deletion_coverages.count(cur_id) ? 0 : deletion_coverages[cur_id];
        Position cur_pos;
        cur_pos.set_node_id(cur_id);
        cur_pos.set_is_reverse(graph.get_is_reverse(cur_handle));
        for (size_t i = 0; i < cur_len; ++i) {
            cur_pos.set_offset(i);
            size_t pos_coverage = packer.coverage_at_position(packer.position_in_basis(cur_pos)) + del_coverage;
            if (pos_coverage >= min_coverage) {
                wellford_update(bin_length, mean, M2, pos_coverage);
            }
        }
    }
    return wellford_mean_var(bin_length, mean, M2, true);
}

vector<tuple<size_t, size_t, double, double>> binned_packed_depth(const Packer& packer, const string& path_name, size_t bin_size,
                                                                  size_t min_coverage, bool include_deletions) {

    const PathHandleGraph& graph = dynamic_cast<const PathHandleGraph&>(*packer.get_graph());
    path_handle_t path_handle = graph.get_path_handle(path_name);
    
    // one scan of our path to collect the bins
    step_handle_t start_step = graph.path_begin(path_handle);
    step_handle_t end_step = graph.path_end(path_handle);
    vector<pair<size_t, step_handle_t>> bins; // start offset / start step of each bin
    size_t offset = 0;
    size_t cur_bin_size = bin_size;
    for (step_handle_t cur_step = start_step; cur_step != end_step; cur_step = graph.get_next_step(cur_step)) {
        if (cur_bin_size >= bin_size) {
            bins.push_back(make_pair(offset, cur_step));
            cur_bin_size = 0;
        }
        size_t node_len = graph.get_length(graph.get_handle_of_step(cur_step));
        offset += node_len;
        cur_bin_size += node_len;
    }

    // parallel scan to compute the coverages
    vector<tuple<size_t, size_t, double, double>> binned_depths(bins.size());
#pragma omp parallel for
    for (size_t i = 0; i < bins.size(); ++i) {
        step_handle_t bin_start_step = bins[i].second;
        step_handle_t bin_end_step = i < bins.size() - 1 ? bins[i+1].second : end_step;
        size_t bin_start = bins[i].first;
        size_t bin_end = i < bins.size() - 1 ? bins[i+1].first : offset;
        pair<double, double> coverage = packed_depth_of_bin(packer, bin_start_step, bin_end_step, min_coverage, include_deletions);
        binned_depths[i] = make_tuple(bin_start, bin_end, coverage.first, coverage.second);
    }

    return binned_depths;
}


// draw (roughly) max_nodes nodes from the graph using the random seed
static unordered_map<nid_t, size_t> sample_nodes(const HandleGraph& graph, size_t max_nodes, size_t random_seed) {
    default_random_engine generator(random_seed);
    uniform_real_distribution<double> distribution(0, 1);
    double cutoff = std::min((double)1.0, (double)max_nodes / (double)graph.get_node_count());
    unordered_map<nid_t, size_t> sampled_nodes;
    graph.for_each_handle([&](handle_t handle) {
        if (cutoff == 1. || cutoff <= distribution(generator)) {
            sampled_nodes[graph.get_id(handle)] = 0;
        }
      });
    return sampled_nodes;
}

// update the coverage from an alignment.  only count nodes that are in the map already
static void update_sample_gam_depth(const Alignment& aln, unordered_map<nid_t, size_t>& node_coverage) {
    const Path& path = aln.path();
    for (int i = 0; i < path.mapping_size(); ++i) {
        const Mapping& mapping = path.mapping(i);
        nid_t node_id = mapping.position().node_id();
        if (node_coverage.count(node_id)) {
            // we add the number of bases covered
            node_coverage[node_id] += mapping_from_length(mapping);
        } 
    }
}

// sum up the results from the different threads and return the average.
// if a min_coverage is given, nodes with less coverage are ignored
static pair<double, double> combine_and_average_node_coverages(const HandleGraph& graph, vector<unordered_map<nid_t, size_t>>& node_coverages, size_t min_coverage) {
    for (int i = 1; i < node_coverages.size(); ++i) {
        for (const auto& node_cov : node_coverages[i]) {
            node_coverages[0][node_cov.first] += node_cov.second;
        }
    }
    size_t count = 0;
    double mean = 0.;
    double M2 = 0.;
    for (const auto & node_cov : node_coverages[0]) {
        if (node_cov.second >= min_coverage) {
            // we normalize the bases covered by the node length as we sum
            double node_len = graph.get_length(graph.get_handle(node_cov.first));
            wellford_update(count, mean, M2, (double)node_cov.second / node_len);
        }
    }

    return wellford_mean_var(count, mean, M2, count < graph.get_node_count());
}


pair<double, double> sample_gam_depth(const HandleGraph& graph, istream& gam_stream, size_t max_nodes, size_t random_seed, size_t min_coverage, size_t min_mapq) {
    // one node counter per thread
    vector<unordered_map<nid_t, size_t>> node_coverages(get_thread_count(), sample_nodes(graph, max_nodes, random_seed));

    function<void(Alignment& aln)> aln_callback = [&](Alignment& aln) {
        if (aln.mapping_quality() >= min_mapq) {
            update_sample_gam_depth(aln, node_coverages[omp_get_thread_num()]);
        }
    };
    vg::io::for_each_parallel(gam_stream, aln_callback);
    return combine_and_average_node_coverages(graph, node_coverages, min_coverage);
}

pair<double, double> sample_gam_depth(const HandleGraph& graph, const vector<Alignment>& alignments, size_t max_nodes, size_t random_seed, size_t min_coverage, size_t min_mapq) {
    // one node counter per thread
    vector<unordered_map<nid_t, size_t>> node_coverages(get_thread_count(), sample_nodes(graph, max_nodes, random_seed));

#pragma omp parallel for
    for (size_t i = 0; i < alignments.size(); ++i) {
        if (alignments[i].mapping_quality() >= min_mapq) {
            update_sample_gam_depth(alignments[i], node_coverages[omp_get_thread_num()]);
        }
    }
    return combine_and_average_node_coverages(graph, node_coverages, min_coverage);
}



}




}

