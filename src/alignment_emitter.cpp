/**
 * \file alignment_emitter.cpp
 *
 * Implements a system for emitting alignments and groups of alignments in multiple formats.
 */

#include "alignment_emitter.hpp"
#include "alignment.hpp"
#include "json2pb.h"
#include <vg/io/hfile_cppstream.hpp>
#include <vg/io/stream.hpp>

#include <sstream>

namespace vg {
using namespace std;

// Implement all the single-read methods in terms of one-read batches
void AlignmentEmitter::emit_single(Alignment&& aln) {
    vector<Alignment> batch = { aln };
    emit_singles(std::move(batch));
}
void AlignmentEmitter::emit_mapped_single(vector<Alignment>&& alns) {
    vector<vector<Alignment>> batch = { alns };
    emit_mapped_singles(std::move(batch));
}
void AlignmentEmitter::emit_pair(Alignment&& aln1, Alignment&& aln2, int64_t tlen_limit) {
    vector<Alignment> batch1 = { aln1 };
    vector<Alignment> batch2 = { aln2 };
    vector<int64_t> tlen_limit_batch(1, tlen_limit);
    emit_pairs(std::move(batch1), std::move(batch2), std::move(tlen_limit_batch));
}
void AlignmentEmitter::emit_mapped_pair(vector<Alignment>&& alns1, vector<Alignment>&& alns2, int64_t tlen_limit) {
    vector<vector<Alignment>> batch1 = { alns1 };
    vector<vector<Alignment>> batch2 = { alns2 };
    vector<int64_t> tlen_limit_batch(1, tlen_limit);
    emit_mapped_pairs(std::move(batch1), std::move(batch2), std::move(tlen_limit_batch));
}

unique_ptr<AlignmentEmitter> get_alignment_emitter(const string& filename, const string& format,
    const map<string, int64_t>& path_length, size_t max_threads) {

    // Make the backing, non-buffered emitter
    AlignmentEmitter* backing = nullptr;
    if (format == "GAM" || format == "JSON") {
        // Make an emitter that supports VG formats
        backing = new VGAlignmentEmitter(filename, format, max_threads);
    } else if (format == "SAM" || format == "BAM" || format == "CRAM") {
        // Make an emitter that supports HTSlib formats
        backing = new HTSAlignmentEmitter(filename, format, path_length, max_threads);
    } else if (format == "TSV") {
        backing = new TSVAlignmentEmitter(filename, max_threads);
    } else {
        cerr << "error [vg::get_alignment_emitter]: Unimplemented output format " << format << endl;
        exit(1);
    }
    
    // Wrap it in a unique_ptr that will delete it
    return unique_ptr<AlignmentEmitter>(backing);
}

TSVAlignmentEmitter::TSVAlignmentEmitter(const string& filename, size_t max_threads) :
    out_file(filename == "-" ? nullptr : new ofstream(filename)),
    multiplexer(out_file.get() != nullptr ? *out_file : cout, max_threads) {
    
    if (out_file.get() != nullptr && !*out_file) {
        // Make sure we opened a file if we aren't writing to standard output
        cerr << "[vg::TSVAlignmentEmitter] failed to open " << filename << " for writing" << endl;
        exit(1);
    }
}

void TSVAlignmentEmitter::emit_singles(vector<Alignment>&& aln_batch) {
    for (auto&& aln : aln_batch) {
        emit(std::move(aln));
    }
    multiplexer.register_breakpoint(omp_get_thread_num());
}

void TSVAlignmentEmitter::emit_mapped_singles(vector<vector<Alignment>>&& alns_batch) {
    for (auto&& alns : alns_batch) {
        for (auto&& aln : alns) {
            emit(std::move(aln));
        }
    }
    multiplexer.register_breakpoint(omp_get_thread_num());
}

void TSVAlignmentEmitter::emit_pairs(vector<Alignment>&& aln1_batch,
                                     vector<Alignment>&& aln2_batch, 
                                     vector<int64_t>&& tlen_limit_batch) {
    // Ignore the tlen limit.
    assert(aln1_batch.size() == aln2_batch.size());
    for (size_t i = 0; i < aln1_batch.size(); i++) {
        // Emit each pair in order as read 1, then read 2
        emit(std::move(aln1_batch[i]));
        emit(std::move(aln2_batch[i]));
    }
    multiplexer.register_breakpoint(omp_get_thread_num());
}


void TSVAlignmentEmitter::emit_mapped_pairs(vector<vector<Alignment>>&& alns1_batch,
                                            vector<vector<Alignment>>&& alns2_batch,
                                            vector<int64_t>&& tlen_limit_batch) {
    assert(alns1_batch.size() == alns2_batch.size());
    for (size_t i = 0; i < alns1_batch.size(); i++) {
        // For each pair
        assert(alns1_batch[i].size() == alns2_batch[i].size());
        for (size_t j = 0; j < alns1_batch[i].size(); j++) {
            // Emit read 1 and read 2 pairs, together
            emit(std::move(alns1_batch[i][j]));
            emit(std::move(alns2_batch[i][j]));
        }
    }
    multiplexer.register_breakpoint(omp_get_thread_num());
}

void TSVAlignmentEmitter::emit(Alignment&& aln) {
    Position refpos;
    if (aln.refpos_size()) {
        refpos = aln.refpos(0);
    }

    // Get the stream to write to
    ostream& out = multiplexer.get_thread_stream(omp_get_thread_num());

    out << aln.name() << "\t"
        << refpos.name() << "\t"
        << refpos.offset() << "\t"
        << aln.mapping_quality() << "\t"
        << aln.score() << "\n";
}

// Give the footer length for rewriting BGZF EOF markers.
const size_t HTSAlignmentEmitter::BGZF_FOOTER_LENGTH = 28;

HTSAlignmentEmitter::HTSAlignmentEmitter(const string& filename, const string& format,
    const map<string, int64_t>& path_length, size_t max_threads) :
    out_file(filename == "-" ? nullptr : new ofstream(filename)),
    multiplexer(out_file.get() != nullptr ? *out_file : cout, max_threads),
    format(format), path_length(path_length),
    backing_files(max_threads, nullptr), sam_files(max_threads, nullptr),
    atomic_header(nullptr), sam_header(), header_mutex(), output_is_bgzf(format != "SAM"),
    hts_mode() {
    
    // We can't work with no streams to multiplex, because we need to be able
    // to write BGZF EOF blocks throught he multiplexer at destruction.
    assert(max_threads > 0);
    
    if (out_file.get() != nullptr && !*out_file) {
        // Make sure we opened a file if we aren't writing to standard output
        cerr << "[vg::HTSAlignmentEmitter] failed to open " << filename << " for writing" << endl;
        exit(1);
    }
    
    // Make sure we have an HTS format
    assert(format == "SAM" || format == "BAM" || format == "CRAM");
    
    // Compute the file mode to send to HTSlib depending on output format
    char out_mode[5];
    string out_format = "";
    strcpy(out_mode, "w");
    if (format == "BAM") {
        out_format = "b";
    } else if (format == "CRAM") {
        out_format = "c";
    } else {
        // Must be SAM
        out_format = "";
    }
    strcat(out_mode, out_format.c_str());
    int compress_level = 9; // TODO: support other compression levels
    if (compress_level >= 0) {
        char tmp[2];
        tmp[0] = compress_level + '0'; tmp[1] = '\0';
        strcat(out_mode, tmp);
    }
    // Save to a C++ string that we will use later.
    hts_mode = out_mode;
   
    // Each thread will lazily open its samFile*, once it has a header ready
}

HTSAlignmentEmitter::~HTSAlignmentEmitter() {
    // Note that the destructor runs in only one thread, and only when
    // destruction is safe. No need to lock the header.
    if (atomic_header.load() != nullptr) {
        // Delete the header
        bam_hdr_destroy(atomic_header.load());
    }
    
    for (size_t thread_number = 0; thread_number < sam_files.size(); thread_number++) {
        // For each thread, find its samFile*
        auto& sam_file = sam_files.at(thread_number);
    
        if (sam_file != nullptr) {
            // Close out all the open samFile*s and flush their data before the
            // multiplexer destructs
            sam_close(sam_file);
            
            if (output_is_bgzf) {
                // Discard all the BGZF EOF marker blocks
                multiplexer.discard_bytes(thread_number, BGZF_FOOTER_LENGTH);
                
                // Put a barrier so subsequent writes come later.
                multiplexer.register_barrier(thread_number);
            }
        }
    }
    
    if (output_is_bgzf) {
        // Now put one BGZF EOF marker in thread 0's stream.
        // It will be the last thing, after all the barriers, and close the file.
        vg::io::finish(multiplexer.get_thread_stream(0), true);
    }
    
}

bam_hdr_t* HTSAlignmentEmitter::ensure_header(const Alignment& sniff, size_t thread_number) {
    bam_hdr_t* header = atomic_header.load();
    if (header == nullptr) {
        // The header does not exist.
        
        // Lock the header mutex so we have exclusive control of the header
        lock_guard<mutex> header_lock(header_mutex);
        
        // Load into the enclosing scope header. Don't shadow, because the
        // enclosing scope variable is what will get returned.
        header = atomic_header.load();
        if (header == nullptr) {
            // It is our turn to make the header.
        
            // Sniff out the read group and sample, and map from RG to sample
            map<string, string> rg_sample;
            if (!sniff.sample_name().empty() && !sniff.read_group().empty()) {
                // We have a sample and a read group
                rg_sample[sniff.read_group()] = sniff.sample_name();
            }
            
            // Make the header
            header = hts_string_header(sam_header, path_length, rg_sample);
            
            // Initialize the SAM file for this thread and actually keep the header
            // we write, since we are the first thread.
            initialize_sam_file(header, thread_number, true);
            
            // Save back to the atomic only after the header has been written and
            // it is safe for other threads to use it.
            atomic_header.store(header);
            
            // We made the header and the SAM file.
            return header;
        }
    }
    
    // Otherwise, someone else beat us to creating the header.
    // Header is ready. We just need to create the samFile* for this thread with it if it doesn't exist.
    
    if (sam_files[thread_number] == nullptr) {
        // The header has been created and written, but hasn't been used to initialize our samFile* yet.
        initialize_sam_file(header, thread_number);
    }
    
    return header;
}

void HTSAlignmentEmitter::convert_unpaired(Alignment& aln, vector<bam1_t*>& dest) {
    // Look up the stuff we need from the Alignment to express it in BAM.
    // We assume the position is available in refpos(0)
    assert(aln.refpos_size() == 1);
    
    size_t path_len = 0;
    if (aln.refpos(0).name() != "") {
        path_len = path_length.at(aln.refpos(0).name()); 
    }
    // Extract the position so that it could be adjusted by cigar_against_path if we decided to supperss softclips. Which we don't.
    // TODO: Separate out softclip suppression.
    int64_t pos = aln.refpos(0).offset();
    vector<pair<int, char>> cigar = cigar_against_path(aln, aln.refpos(0).is_reverse(), pos, path_len, 0);
    // TODO: We're passing along a text header so we can make a SAM file so
    // we can make a BAM record by re-reading it, which we can then
    // possibly output as SAM again. Make this less complicated.
    dest.emplace_back(alignment_to_bam(sam_header,
                                       aln,
                                       aln.refpos(0).name(),
                                       pos,
                                       aln.refpos(0).is_reverse(),
                                       cigar));
}

void HTSAlignmentEmitter::convert_paired(Alignment& aln1, Alignment& aln2, int64_t tlen_limit, vector<bam1_t*>& dest) {
    // Look up the stuff we need from the Alignment to express it in BAM.
    // We assume the position is available in refpos(0)
    assert(aln1.refpos_size() == 1);
    assert(aln2.refpos_size() == 1);
    
    size_t path_len1 = 0;
    if (aln1.refpos(0).name() != "") {
        path_len1 = path_length.at(aln1.refpos(0).name()); 
    }
    size_t path_len2 = 0;
    if (aln2.refpos(0).name() != "") {
        path_len2 = path_length.at(aln2.refpos(0).name()); 
    }
    
    // Extract the position so that it could be adjusted by cigar_against_path if we decided to supperss softclips. Which we don't.
    // TODO: Separate out softclip suppression.
    int64_t pos1 = aln1.refpos(0).offset();
    int64_t pos2 = aln2.refpos(0).offset();
    vector<pair<int, char>> cigar1 = cigar_against_path(aln1, aln1.refpos(0).is_reverse(), pos1, path_len1, 0);
    vector<pair<int, char>> cigar2 = cigar_against_path(aln2, aln2.refpos(0).is_reverse(), pos2, path_len2, 0);
    
    // Determine the TLEN for each read.
    auto tlens = compute_template_lengths(pos1, cigar1, pos2, cigar2);
    
    // TODO: We're passing along a text header so we can make a SAM file so
    // we can make a BAM record by re-reading it, which we can then
    // possibly output as SAM again. Make this less complicated.
    dest.emplace_back(alignment_to_bam(sam_header,
                                       aln1,
                                       aln1.refpos(0).name(),
                                       pos1,
                                       aln1.refpos(0).is_reverse(),
                                       cigar1,
                                       aln2.refpos(0).name(),
                                       pos2,
                                       aln2.refpos(0).is_reverse(),
                                       tlens.first,
                                       tlen_limit));
    dest.emplace_back(alignment_to_bam(sam_header,
                                       aln2,
                                       aln2.refpos(0).name(),
                                       pos2,
                                       aln2.refpos(0).is_reverse(),
                                       cigar2,
                                       aln1.refpos(0).name(),
                                       pos1,
                                       aln1.refpos(0).is_reverse(),
                                       tlens.second,
                                       tlen_limit));
    
}

void HTSAlignmentEmitter::save_records(bam_hdr_t* header, vector<bam1_t*>& records, size_t thread_number) {
    // We need a header and an extant samFile*
    assert(header != nullptr);
    assert(sam_files[thread_number] != nullptr);
    
    for (auto& b : records) {
        // Emit each record
        
        if (sam_write1(sam_files[thread_number], header, b) == 0) {
            cerr << "[vg::HTSAlignmentEmitter] error: writing to output file failed" << endl;
            exit(1);
        }
    }
    
    for (auto& b : records) {
        // Deallocate all the records
        bam_destroy1(b);
    }
    
    if (multiplexer.want_breakpoint(thread_number)) {
        // We have written enough that we ought to give the multiplexer a chance to multiplex soon.
        // There's no way to do this without closing and re-opening the HTS file.
        // So just tear down and reamke the samFile* for this thread.
        initialize_sam_file(header, thread_number);
    }
}

void HTSAlignmentEmitter::initialize_sam_file(bam_hdr_t* header, size_t thread_number, bool keep_header) {
    if (sam_files[thread_number] != nullptr) {
        // A samFile* has been created already. Clear it out.
        // Closing the samFile* flushes and destroys the BGZF and hFILE* backing it.
        sam_close(sam_files[thread_number]);
        
        // Now we know there's a closing empty BGZF block that htslib puts to
        // mark EOF. We don't want that in the middle of our stream because it
        // is weird and we aren't actually at EOF.
        // We know how long it is, so we will trim it off.
        multiplexer.discard_bytes(thread_number, BGZF_FOOTER_LENGTH);
        
        // Now place a breakpoint right where we were before that empty block.
        multiplexer.register_breakpoint(thread_number);
    }
    
    // Create a new samFile* for this thread
    // hts_mode was filled in when the header was.
    // hts_hopen demands a filename, but appears to just store it, and
    // doesn't document how required it it.
    backing_files[thread_number] = vg::io::hfile_wrap(multiplexer.get_thread_stream(thread_number));
    sam_files[thread_number] = hts_hopen(backing_files[thread_number], "-", hts_mode.c_str());
    
    if (sam_files[thread_number] == nullptr) {
        // We couldn't open the output samFile*
        cerr << "[vg::HTSAlignmentEmitter] failed to open internal stream for writing " << format << " output" << endl;
        exit(1);
    }
    
    // Write the header again, which is the only way to re-initialize htslib's internals.
    // Remember that sam_hdr_write flushes the BGZF to the hFILE*, but does not flush the hFILE*.
    if (sam_hdr_write(sam_files[thread_number], header) != 0) {
        cerr << "[vg::HTSAlignmentEmitter] error: failed to write the SAM header" << endl;
        exit(1);
    }
    
    // Now flush it out of the hFILE* buffer into the backing C++ stream
    if (hflush(backing_files[thread_number]) != 0) {
        cerr << "[vg::HTSAlignmentEmitter] error: failed to flush the SAM header" << endl;
        exit(1);
    }
    
    if (keep_header) {
        // We are the first thread to write a header, so we actually want it.
        // Place a barrier which is also a breakpoint, so all subsequent writes come later.
        multiplexer.register_barrier(thread_number);
    } else {
        // Discard the header so it won't be in the resulting file again
        multiplexer.discard_to_breakpoint(thread_number);
    }
}

void HTSAlignmentEmitter::emit_singles(vector<Alignment>&& aln_batch) {
    if (aln_batch.empty()) {
        // Nothing to do
        return;
    }
    
    // Work out what thread we are
    size_t thread_number = omp_get_thread_num();
    
    // Make sure header exists
    bam_hdr_t* header = ensure_header(aln_batch.front(), thread_number);
    assert(header != nullptr);
    assert(sam_files[thread_number] != nullptr);
    
    vector<bam1_t*> records;
    records.reserve(aln_batch.size());
    
    for (auto& aln : aln_batch) {
        // Convert each alignment to HTS format
        convert_unpaired(aln, records);
    }
    
    // Save to the stream for this thread.
    save_records(header, records, thread_number);
}

void HTSAlignmentEmitter::emit_mapped_singles(vector<vector<Alignment>>&& alns_batch) {
    // Count the total alignments to do
    size_t count = 0;
    // And find an alignment to base the header on
    Alignment* sniff = nullptr;
    for (auto& alns : alns_batch) {
        count += alns.size();
        if (!alns.empty() && sniff == nullptr) {
            sniff = &alns.front();
        }
    }
    
    if (count == 0) {
        // Nothing to do
        return;
    }
    
    // Work out what thread we are
    size_t thread_number = omp_get_thread_num();
    
    // Make sure header exists
    assert(sniff != nullptr);
    bam_hdr_t* header = ensure_header(*sniff, thread_number);
    assert(header != nullptr);
    assert(sam_files[thread_number] != nullptr);
    
    vector<bam1_t*> records;
    records.reserve(count);
    
    for (auto& alns : alns_batch) {
        for (auto& aln : alns) {
            // Convert each alignment to HTS format
            convert_unpaired(aln, records);
        }
    }
    
    // Save to the stream for this thread.
    save_records(header, records, thread_number);

}


void HTSAlignmentEmitter::emit_pairs(vector<Alignment>&& aln1_batch,
                                     vector<Alignment>&& aln2_batch,
                                     vector<int64_t>&& tlen_limit_batch) {
    assert(aln1_batch.size() == aln2_batch.size());
    assert(aln1_batch.size() == tlen_limit_batch.size());
    
    
    if (aln1_batch.empty()) {
        // Nothing to do
        return;
    }
    
    // Work out what thread we are
    size_t thread_number = omp_get_thread_num();
    
    // Make sure header exists
    bam_hdr_t* header = ensure_header(aln1_batch.front(), thread_number);
    assert(header != nullptr);
    assert(sam_files[thread_number] != nullptr);
    
    vector<bam1_t*> records;
    records.reserve(aln1_batch.size() * 2);
    
    for (size_t i = 0; i < aln1_batch.size(); i++) {
        // Convert each alignment pair to HTS format
        convert_paired(aln1_batch[i], aln2_batch[i], tlen_limit_batch[i], records);
    }
    
    // Save to the stream for this thread.
    save_records(header, records, thread_number);
}
    
    
void HTSAlignmentEmitter::emit_mapped_pairs(vector<vector<Alignment>>&& alns1_batch, 
                                            vector<vector<Alignment>>&& alns2_batch,
                                            vector<int64_t>&& tlen_limit_batch) {
                                            
    assert(alns1_batch.size() == alns2_batch.size());
    assert(alns1_batch.size() == tlen_limit_batch.size());
    
    // Count the total alignments to do
    size_t count = 0;
    // And find an alignment to base the header on
    Alignment* sniff = nullptr;
    for (size_t i = 0; i < alns1_batch.size(); i++) {
        // Go through all pairs
        
        // Make sure each end of the pair has the same number of mappings
        assert(alns1_batch[i].size() == alns2_batch[i].size());
        
        count += alns1_batch[i].size() * 2;
        if (!alns1_batch[i].empty() && sniff == nullptr) {
            sniff = &alns1_batch[i].front();
        }
    }
    
    if (count == 0) {
        // Nothing to do
        return;
    }
    
    // Work out what thread we are
    size_t thread_number = omp_get_thread_num();
    
    // Make sure header exists
    assert(sniff != nullptr);
    bam_hdr_t* header = ensure_header(*sniff, thread_number);
    assert(header != nullptr);
    assert(sam_files[thread_number] != nullptr);
    
    vector<bam1_t*> records;
    records.reserve(count);
    
    for (size_t i = 0; i < alns1_batch.size(); i++) {
        for (size_t j = 0; j < alns1_batch[i].size(); j++) {
            // Convert each alignment pair to HTS format
            convert_paired(alns1_batch[i][j], alns2_batch[i][j], tlen_limit_batch[i], records);
        }
    }
    
    // Save to the stream for this thread.
    save_records(header, records, thread_number);
}

VGAlignmentEmitter::VGAlignmentEmitter(const string& filename, const string& format, size_t max_threads):
    out_file(filename == "-" ? nullptr : new ofstream(filename)),
    multiplexer(out_file.get() != nullptr ? *out_file : cout, max_threads) {
    
    // We only support GAM and JSON formats
    assert(format == "GAM" || format == "JSON");
    
#ifdef debug
    cerr << "Creating VGAlignmentEmitter for " << format << " format to output file " << filename << " @ " << out_file.get() << endl;
    if (out_file.get() != nullptr) {
        cerr << "Output stream is at " << out_file->tellp() << endl;
    } else {
        cerr << "Output stream is at " << cout.tellp() << endl;
    }
#endif
    
    if (filename != "-") {
        // Check the file
        if (!*out_file) {
            // We couldn't get it open
            cerr << "[vg::VGAlignmentEmitter] failed to open " << filename << " for writing " << format << " output" << endl;
            exit(1);
        }
    }
    
    if (format == "GAM") {
        // We need per-thread emitters
        proto.reserve(max_threads);
        for (size_t i = 0; i < max_threads; i++) {
            // Make an emitter for each thread.
            proto.emplace_back(new vg::io::ProtobufEmitter<Alignment>(multiplexer.get_thread_stream(i)));
        }
    }
    
    // We later infer our format and output destination from out_file and proto being empty/set.
}

VGAlignmentEmitter::~VGAlignmentEmitter() {
#ifdef debug
    cerr << "Destroying VGAlignmentEmitter" << endl;
    if (out_file.get() != nullptr) {
        cerr << "Output stream is at " << out_file->tellp() << endl;
    } else {
        cerr << "Output stream is at " << cout.tellp() << endl;
    }
#endif

    if (!proto.empty()) {
        for (auto& emitter : proto) {
            // Flush each ProtobufEmitter
            emitter->flush(); 
            // Make it go away before the stream
            emitter.reset();
        }
    }
    
#ifdef debug
    cerr << "Destroyed VGAlignmentEmitter" << endl;
#endif
}

void VGAlignmentEmitter::emit_singles(vector<Alignment>&& aln_batch) {
    size_t thread_number = omp_get_thread_num();
    if (!proto.empty()) {
        // Save in protobuf
#ifdef debug
        #pragma omp critical (cerr)
        cerr << "VGAlignmentEmitter emitting " << aln_batch.size() << " reads to Protobuf in thread " << thread_number << endl;
#endif
        proto[thread_number]->write_many(std::move(aln_batch));
        if (multiplexer.want_breakpoint(thread_number)) {
            // The multiplexer wants our data.
            // Flush and create a breakpoint.
            proto[thread_number]->flush();
            multiplexer.register_breakpoint(thread_number);
        }
    } else {
        // Serialize to a string in our thread
        stringstream data;
        for (auto& aln : aln_batch) {
            multiplexer.get_thread_stream(thread_number) << pb2json(aln) << endl;
        }
        // No need to flush, we can always register a breakpoint.
        multiplexer.register_breakpoint(thread_number);
    }
}

void VGAlignmentEmitter::emit_mapped_singles(vector<vector<Alignment>>&& alns_batch) {
    size_t thread_number = omp_get_thread_num();
    if (!proto.empty()) {
        // Count up alignments
        size_t count = 0;
        for (auto& alns : alns_batch) {
            count += alns.size();
        }

#ifdef debug
        #pragma omp critical (cerr)
        cerr << "VGAlignmentEmitter emitting " << count << " alignments to Protobuf in thread " << thread_number << endl;
#endif
        
        if (count == 0) {
            // Nothing to do
            return;
        }
        
        // Collate one big vector to write together
        vector<Alignment> all;
        all.reserve(count);
        for (auto&& alns : alns_batch) {
            std::move(alns.begin(), alns.end(), std::back_inserter(all));
        }
        
        // Save in protobuf
        proto[thread_number]->write_many(std::move(all));
        if (multiplexer.want_breakpoint(thread_number)) {
            // The multiplexer wants our data.
            // Flush and create a breakpoint.
            proto[thread_number]->flush();
            multiplexer.register_breakpoint(thread_number);
#ifdef debug
            cerr << "Sent breakpoint from thread " << thread_number << endl;
#endif
        }
    } else {
        // Serialize to a string in our thread
        for (auto& alns : alns_batch) {
            for (auto& aln : alns) {
                multiplexer.get_thread_stream(thread_number) << pb2json(aln) << endl;
            }
        }
        // No need to flush, we can always register a breakpoint.
        multiplexer.register_breakpoint(thread_number);
#ifdef debug
        cerr << "Sent " << alns_batch.size() << " batches from thread " << thread_number << " followed by a breakpoint" << endl;
#endif
    }
}

void VGAlignmentEmitter::emit_pairs(vector<Alignment>&& aln1_batch,
                                    vector<Alignment>&& aln2_batch,
                                    vector<int64_t>&& tlen_limit_batch) {
    // Sizes need to match up
    assert(aln1_batch.size() == aln2_batch.size());
    assert(aln1_batch.size() == tlen_limit_batch.size());
    
    size_t thread_number = omp_get_thread_num();
    
    if (!proto.empty()) {
        // Save in protobuf
        
#ifdef debug
        #pragma omp critical (cerr)
        cerr << "VGAlignmentEmitter emitting paired reads to Protobuf in thread " << thread_number << endl;
#endif
        
        // Arrange into a vector in collated order
        vector<Alignment> all;
        all.reserve(aln1_batch.size() + aln2_batch.size());
        for (size_t i = 0; i < aln1_batch.size(); i++) {
            all.emplace_back(std::move(aln1_batch[i]));
            all.emplace_back(std::move(aln2_batch[i]));
        }
        
        // Save in protobuf
        proto[thread_number]->write_many(std::move(all));
        if (multiplexer.want_breakpoint(thread_number)) {
            // The multiplexer wants our data.
            // Flush and create a breakpoint.
            proto[thread_number]->flush();
            multiplexer.register_breakpoint(thread_number);
        }
    } else {
        // Serialize to a string in our thread in collated order
        stringstream data;
        for (size_t i = 0; i < aln1_batch.size(); i++) {
            multiplexer.get_thread_stream(thread_number) << pb2json(aln1_batch[i]) << endl
                << pb2json(aln2_batch[i]) << endl;
        }
        // No need to flush, we can always register a breakpoint.
        multiplexer.register_breakpoint(thread_number);
    }
}

void VGAlignmentEmitter::emit_mapped_pairs(vector<vector<Alignment>>&& alns1_batch,
                                           vector<vector<Alignment>>&& alns2_batch,
                                           vector<int64_t>&& tlen_limit_batch) {
    // Sizes need to match up
    assert(alns1_batch.size() == alns2_batch.size());
    assert(alns1_batch.size() == tlen_limit_batch.size());
    
    size_t thread_number = omp_get_thread_num();
    
    if (!proto.empty()) {
        // Save in protobuf
        
        // Count up all the alignments
        size_t count = 0;
        for (size_t i = 0; i < alns1_batch.size(); i++) {
            assert(alns1_batch[i].size() == alns2_batch[i].size());
            count += alns1_batch[i].size() * 2;
        }
        
#ifdef debug
        #pragma omp critical (cerr)
        cerr << "VGAlignmentEmitter emitting " << count << " mapped pairs to Protobuf in thread " << thread_number << endl;
#endif
        
        if (count == 0) {
            // Nothing to do
            return;
        }
        
        // Arrange into an interleaved vector
        vector<Alignment> all;
        all.reserve(count);
        for (size_t i = 0; i < alns1_batch.size(); i++) {
            for (size_t j = 0; j < alns1_batch[i].size(); j++) {
                all.emplace_back(std::move(alns1_batch[i][j]));
                all.emplace_back(std::move(alns2_batch[i][j]));
            }
        }
        
        // Save in protobuf
        proto[thread_number]->write_many(std::move(all));
        if (multiplexer.want_breakpoint(thread_number)) {
            // The multiplexer wants our data.
            // Flush and create a breakpoint.
            proto[thread_number]->flush();
            multiplexer.register_breakpoint(thread_number);
        }
    } else {
        // Serialize to an interleaved string in our thread
        stringstream data;
        for (size_t i = 0; i < alns1_batch.size(); i++) {
            assert(alns1_batch[i].size() == alns1_batch[i].size());
            for (size_t j = 0; j < alns1_batch[i].size(); j++) {
                multiplexer.get_thread_stream(thread_number) << pb2json(alns1_batch[i][j]) << endl
                    << pb2json(alns2_batch[i][j]) << endl;
            }
        }
        
        // No need to flush, we can always register a breakpoint.
        multiplexer.register_breakpoint(thread_number);
    }
}

}
