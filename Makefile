DEP_DIR:=./deps
SRC_DIR:=src
ALGORITHMS_SRC_DIR:=$(SRC_DIR)/algorithms
IO_SRC_DIR:=$(SRC_DIR)/io
SUBCOMMAND_SRC_DIR:=$(SRC_DIR)/subcommand
UNITTEST_SRC_DIR:=$(SRC_DIR)/unittest
BIN_DIR:=bin
OBJ_DIR:=obj
ALGORITHMS_OBJ_DIR:=$(OBJ_DIR)/algorithms
IO_OBJ_DIR:=$(OBJ_DIR)/io
SUBCOMMAND_OBJ_DIR:=$(OBJ_DIR)/subcommand
UNITTEST_OBJ_DIR:=$(OBJ_DIR)/unittest
LIB_DIR:=lib
# INC_DIR must be a relative path
INC_DIR:=include
CWD:=$(shell pwd)
CXX ?= g++

EXE:=vg

all: $(BIN_DIR)/$(EXE)

# Magic dependencies (see <http://make.mad-scientist.net/papers/advanced-auto-dependency-generation/#tldr>)
include $(wildcard $(OBJ_DIR)/*.d)
include $(wildcard $(ALGORITHMS_OBJ_DIR)/*.d)
include $(wildcard $(IO_OBJ_DIR)/*.d)
include $(wildcard $(SUBCOMMAND_OBJ_DIR)/*.d)
include $(wildcard $(UNITTEST_OBJ_DIR)/*.d)

# We don't ask for -fopenmp here because how we get it can depend on the compiler.
CXXFLAGS := -O3 -Werror=return-type -std=c++14 -ggdb -g -MMD -MP $(CXXFLAGS)

# Set include flags. All -I options need to go in here, so the first directory listed is genuinely searched first.
INCLUDE_FLAGS:=-I$(CWD)/$(INC_DIR) -I. -I$(CWD)/$(SRC_DIR) -I$(CWD)/$(UNITTEST_SRC_DIR) -I$(CWD)/$(SUBCOMMAND_SRC_DIR) -I$(CWD)/$(INC_DIR)/dynamic -I$(CWD)/$(INC_DIR)/sonLib $(shell pkg-config --cflags cairo jansson)

# Define libraries to link against. Make sure to always link statically against
# htslib and libdeflate and Protobuf so that we can use position-dependent code
# there for speed.
LD_LIB_FLAGS:= -L$(CWD)/$(LIB_DIR) $(CWD)/$(LIB_DIR)/libvgio.a -lvcflib -lgssw -lssw -lprotobuf -lsublinearLS $(CWD)/$(LIB_DIR)/libhts.a $(CWD)/$(LIB_DIR)/libdeflate.a -lpthread -ljansson -lncurses -lgcsa2 -lgbwtgraph -lgbwt -ldivsufsort -ldivsufsort64 -lvcfh -lraptor2 -lpinchesandcacti -l3edgeconnected -lsonlib -lfml -llz4 -lstructures -lvw -lboost_program_options -lallreduce -lbdsg -lxg -lsdsl -lhandlegraph
# Use pkg-config to find Cairo and all the libs it uses
LD_LIB_FLAGS += $(shell pkg-config --libs --static cairo jansson)

# Travis needs -latomic for all builds *but* GCC on Mac
ifeq ($(strip $(shell $(CXX) -latomic /dev/null -o/dev/null 2>&1 | grep latomic | wc -l)), 0)
    # Use -latomic if the compiler doesn't complain about it
    LD_LIB_FLAGS += -latomic
endif

ifeq ($(shell uname -s),Darwin)
    # We may need libraries from Macports
    # TODO: where does Homebrew keep libraries?
    ifeq ($(shell if [ -d /opt/local/lib ];then echo 1;else echo 0;fi), 1)
        # Use /opt/local/lib if present
        LD_LIB_FLAGS += -L/opt/local/lib
    endif
    ifeq ($(shell if [ -d /usr/local/lib ];then echo 1;else echo 0;fi), 1)
        # Use /usr/local/lib if present.
        LD_LIB_FLAGS += -L/usr/local/lib
    endif
    ifeq ($(shell if [ -d /usr/local/include ];then echo 1;else echo 0;fi), 1)
        # Use /usr/local/include to the end of the include search path.
        INCLUDE_FLAGS += -I /usr/local/include

        ifeq ($(shell if [ -d /usr/local/include/cairo ];then echo 1;else echo 0;fi), 1)	
            # pkg-config is not always smart enough to find Cairo's include path for us.
            # We make sure to grab its directory manually if we see it.
            INCLUDE_FLAGS += -I /usr/local/include/cairo
            LD_LIB_FLAGS += -lcairo
        endif
    endif

    # Our compiler might be clang that lacks -fopenmp support.
    # Sniff that
    ifeq ($(strip $(shell $(CXX) -fopenmp /dev/null -o/dev/null 2>&1 | grep fopenmp | wc -l)), 1)
        # The compiler complained about fopenmp instead of its nonsense input file.
        # We need to use the hard way of getting OpenMP not bundled with the compiler.
        # The compiler only needs to do the preprocessing
        CXXFLAGS += -Xpreprocessor -fopenmp

        # We also need to link it
        LD_LIB_FLAGS += -lomp
    else
        # The compiler is (probably?) GNU GCC
        # On Mac, we need to make sure to configure it to use libc++ like
        # Clang, and not GNU libstdc++.
        # Otherwise, we won't be able to use any C++ system libraries from
        # Homebrew or Macports, which will be built against libc++.

        # See https://stackoverflow.com/q/22228208

        # TODO: ID compiler more reliably instead of depending on it not having OpenMP...
	
        CXXFLAGS += -fopenmp

        # Find includes using Clang
        LIBCXX_INCLUDES := $(shell clang++ -print-search-dirs | perl -ne 's{^libraries: =(.*)}{$$1/../../../} && print')
        # Use them and libc++ and not the normal standard library
        CXXFLAGS := -isystem $(LIBCXX_INCLUDES)/include/c++/v1 -nostdinc++ -nodefaultlibs -lc -lc++ -lc++abi -lgcc_s.1 -Wl,-no_compact_unwind $(CXXFLAGS)

        # Make sure to use the right libgomp to go with libomp
        LD_LIB_FLAGS += -lomp -lgomp.1
    endif
	
    ifeq ($(shell if [ -d /opt/local/lib/libomp ];then echo 1;else echo 0;fi), 1)
        # Use /opt/local/lib/libomp if present, because Macports installs libomp there.
        # Brew is supposed to put it somewhere the compiler can find it by default.
        LD_LIB_FLAGS += -L/opt/local/lib/libomp
        # And we need to find the includes. Homebrew puts them in the normal place
        # but Macports hides them in "libomp"
        INCLUDE_FLAGS += -I/opt/local/include/libomp
    endif

    # And we need to find the includes for OMP. Homebrew puts them in the
    # normal place but macports hides them in "libomp"
    INCLUDE_FLAGS += -I/opt/local/include/libomp

    # We care about building only for the current machine. If we do something
    # more restrictive we can have trouble inlining parts of the standard
    # library that were built for something less restrictive.
    CXXFLAGS += -march=native

    # Note shared libraries are dylibs
    SHARED_SUFFIX = dylib
    # Define options to start and end static linking of libraries.
    # We don't actually do any static linking on Mac, so we leave these empty.
    START_STATIC =
    END_STATIC =

else
    # We are not running on OS X
    # We can also have a normal Unix rpath
    LD_LIB_FLAGS += -Wl,-rpath,$(CWD)/$(LIB_DIR)
    # Make sure to allow backtrace access to all our symbols, even those which are not exported.
    # Absolutely no help in a static build.
    LD_LIB_FLAGS += -rdynamic

    # We want to link against the elfutils libraries
    LD_LIB_FLAGS += -ldwfl -ldw -ldwelf -lelf -lebl

    # We get OpenMP the normal way, using whatever the compiler knows about
    CXXFLAGS += -fopenmp

    # We care about building for SSE4.2 only and not AVX, to have vaguely portable binaries
    CXXFLAGS += -msse4.2
	
    # Note shared libraries are so files
    SHARED_SUFFIX = so
    # Define options to start and end static linking of libraries on GNU ld
    START_STATIC = -Wl,-Bstatic
    END_STATIC = -Wl,-Bdynamic
endif

# Propagate CXXFLAGS to child makes and other build processes
export CXXFLAGS

# These libs need to come after libdw if used, because libdw depends on them
LD_LIB_FLAGS += -ldl -llzma

# Sometimes we need to filter the assembler output. The assembler can run during
# ./configure scripts, compiler calls, or $(MAKE) calls (other than $(MAKE)
# install). So we just stick $(FILTER) at the end of all such commands.
ifeq ($(shell uname -s),Darwin)
    # We need to apply a filter to all our build command output. This discards
    # all the assembler warnings which can overwhelm Travis log storage.
    FILTER=2>&1 | python $(CWD)/scripts/filter-noisy-assembler-warnings.py
    # For the filter to work and not just swallow errors we also need to turn on
    # pipefail in the shell
    SHELL=/bin/bash -o pipefail
else
    # No filter
    FILTER=
endif

ROCKSDB_PORTABLE=PORTABLE=1 # needed to build rocksdb without weird assembler options
# TODO: configure RPATH-equivalent on OS X for finding libraries without environment variables at runtime

# RocksDB's dependecies depend on whether certain compression libraries
# happen to be installed on the build system. Define a lazy macro to
# detect these from its self-configuration. It has to be lazy because
# the configuration (make_config.mk) won't exist until after RocksDB
# is built by this Makefile.
LD_LIB_FLAGS += -lrocksdb
ROCKSDB_LDFLAGS = $(shell grep PLATFORM_LDFLAGS deps/rocksdb/make_config.mk | cut -d '=' -f2 | sed s/-ljemalloc// | sed s/-ltcmalloc// | sed s/-ltbb//)

# When building statically, we need to tell the linker not to bail if it sees multiple definitions.
# libc on e.g. our Jenkins host does not define malloc as weak, so other mallocs can't override it in a static build.
# TODO: Why did this problem only begin to happen when libvw was added?
STATIC_FLAGS=-static -static-libstdc++ -static-libgcc -Wl,--allow-multiple-definition 

# These are put into libvg. Grab everything except main
OBJ = $(filter-out $(OBJ_DIR)/main.o,$(patsubst $(SRC_DIR)/%.cpp,$(OBJ_DIR)/%.o,$(wildcard $(SRC_DIR)/*.cpp)))
# And all the algorithms
ALGORITHMS_OBJ = $(patsubst $(ALGORITHMS_SRC_DIR)/%.cpp,$(ALGORITHMS_OBJ_DIR)/%.o,$(wildcard $(ALGORITHMS_SRC_DIR)/*.cpp))
# And all the IO logic
IO_OBJ = $(patsubst $(IO_SRC_DIR)/%.cpp,$(IO_OBJ_DIR)/%.o,$(wildcard $(IO_SRC_DIR)/*.cpp))

# These aren't put into libvg, but they provide subcommand implementations for the vg bianry
SUBCOMMAND_OBJ = $(patsubst $(SUBCOMMAND_SRC_DIR)/%.cpp,$(SUBCOMMAND_OBJ_DIR)/%.o,$(wildcard $(SUBCOMMAND_SRC_DIR)/*.cpp))

# These aren't put into libvg. But they do go into the main vg binary to power its self-test.
UNITTEST_OBJ = $(patsubst $(UNITTEST_SRC_DIR)/%.cpp,$(UNITTEST_OBJ_DIR)/%.o,$(wildcard $(UNITTEST_SRC_DIR)/*.cpp))

# These aren't put into libvg. They are linked into vg itself to communicate
# things about the platform
CONFIGURATION_OBJ =



RAPTOR_DIR:=deps/raptor
JEMALLOC_DIR:=deps/jemalloc
LOCKFREE_MALLOC_DIR:=deps/lockfree-malloc
SDSL_DIR:=deps/sdsl-lite
SNAPPY_DIR:=deps/snappy
ROCKSDB_DIR:=deps/rocksdb
GCSA2_DIR:=deps/gcsa2
GBWT_DIR:=deps/gbwt
GBWTGRAPH_DIR=deps/gbwtgraph
PROGRESS_BAR_DIR:=deps/progress_bar
FASTAHACK_DIR:=deps/fastahack
FERMI_DIR:=deps/fermi-lite
HTSLIB_DIR:=deps/htslib
VCFLIB_DIR:=deps/vcflib
GSSW_DIR:=deps/gssw
SPARSEHASH_DIR:=deps/sparsehash
SPARSEPP_DIR:=deps/sparsepp
SHA1_DIR:=deps/sha1
DYNAMIC_DIR:=deps/DYNAMIC
SSW_DIR:=deps/ssw/src
LINLS_DIR:=deps/sublinear-Li-Stephens
STRUCTURES_DIR:=deps/structures
BACKWARD_CPP_DIR:=deps/backward-cpp
DOZEU_DIR:=deps/dozeu
ELFUTILS_DIR:=deps/elfutils
BOOST_DIR:=deps/boost-subset
VOWPALWABBIT_DIR:=deps/vowpal_wabbit
LIBDEFLATE_DIR:=deps/libdeflate
LIBVGIO_DIR:=deps/libvgio
LIBHANDLEGRAPH_DIR:=deps/libhandlegraph
LIBBDSG_DIR:=deps/libbdsg
XG_DIR:=deps/xg
MMMULTIMAP_DIR=deps/mmmultimap
IPS4O_DIR=deps/ips4o
BBHASH_DIR=deps/BBHash

# Dependencies that go into libvg's archive
# These go in libvg but come from dependencies
DEP_OBJ =
DEP_OBJ += $(OBJ_DIR)/progress_bar.o
DEP_OBJ += $(OBJ_DIR)/sha1.o
DEP_OBJ += $(OBJ_DIR)/Fasta.o


# These are libraries that we need to build before we link vg.
# It would be nice to dump their contents into libvg to make it stand-alone.
# But that requires fancy ar scripting.
# If you just pass them to ar it puts the library *file* in libvg where nothing can read it.
LIB_DEPS =
LIB_DEPS += $(LIB_DIR)/libsdsl.a
LIB_DEPS += $(LIB_DIR)/libssw.a
LIB_DEPS += $(LIB_DIR)/libsnappy.a
LIB_DEPS += $(LIB_DIR)/librocksdb.a
LIB_DEPS += $(LIB_DIR)/libgcsa2.a
LIB_DEPS += $(LIB_DIR)/libgbwt.a
LIB_DEPS += $(LIB_DIR)/libgbwtgraph.a
LIB_DEPS += $(LIB_DIR)/libhts.a
LIB_DEPS += $(LIB_DIR)/libvcflib.a
LIB_DEPS += $(LIB_DIR)/libgssw.a
LIB_DEPS += $(LIB_DIR)/libvcfh.a
LIB_DEPS += $(LIB_DIR)/libsonlib.a
LIB_DEPS += $(LIB_DIR)/libpinchesandcacti.a
LIB_DEPS += $(LIB_DIR)/libraptor2.a
LIB_DEPS += $(LIB_DIR)/libfml.a
LIB_DEPS += $(LIB_DIR)/libsublinearLS.a
LIB_DEPS += $(LIB_DIR)/libstructures.a
LIB_DEPS += $(LIB_DIR)/libvw.a
LIB_DEPS += $(LIB_DIR)/liballreduce.a
LIB_DEPS += $(LIB_DIR)/libboost_program_options.a
LIB_DEPS += $(LIB_DIR)/libdeflate.a
LIB_DEPS += $(LIB_DIR)/libvgio.a
LIB_DEPS += $(LIB_DIR)/libhandlegraph.a
LIB_DEPS += $(LIB_DIR)/libbdsg.a
LIB_DEPS += $(LIB_DIR)/libxg.a
ifneq ($(shell uname -s),Darwin)
    # On non-Mac (i.e. Linux), where ELF binaries are used, pull in libdw which
    # backward-cpp will use.
    LIB_DEPS += $(LIB_DIR)/libdw.a
    LIB_DEPS += $(LIB_DIR)/libdwfl.a
    LIB_DEPS += $(LIB_DIR)/libdwelf.a
    LIB_DEPS += $(LIB_DIR)/libebl.a
    LIB_DEPS += $(LIB_DIR)/libelf.a
endif

# common dependencies to build before all vg src files
DEPS = $(LIB_DEPS)
DEPS += $(INC_DIR)/gcsa/gcsa.h
DEPS += $(INC_DIR)/gbwt/dynamic_gbwt.h
DEPS += $(INC_DIR)/gbwtgraph/gbwtgraph.h
DEPS += $(INC_DIR)/lru_cache.h
DEPS += $(INC_DIR)/dynamic/dynamic.hpp
DEPS += $(INC_DIR)/sparsehash/sparse_hash_map
DEPS += $(INC_DIR)/sparsepp/spp.h
DEPS += $(INC_DIR)/gfakluge.hpp
DEPS += $(INC_DIR)/sha1.hpp
DEPS += $(INC_DIR)/progress_bar.hpp
DEPS += $(INC_DIR)/backward.hpp
DEPS += $(INC_DIR)/dozeu/dozeu.h
DEPS += $(INC_DIR)/mmmultimap.hpp
DEPS += $(INC_DIR)/ips4o.hpp
DEPS += $(INC_DIR)/raptor2/raptor2.h
DEPS += $(INC_DIR)/BooPHF.h

# Only depend on these files for the final linking stage.	
# These libraries provide no headers to affect the vg build.	
LINK_DEPS =

ifneq ($(shell uname -s),Darwin)
    # Use jemalloc
	LINK_DEPS += $(LIB_DIR)/libjemalloc.a
	LD_LIB_FLAGS += -ljemalloc
endif

.PHONY: clean get-deps deps test set-path static static-docker docs .pre-build .check-environment .check-git .no-git 

# For a normal dynamic build we remove the static build marker
$(BIN_DIR)/$(EXE): $(OBJ_DIR)/main.o $(LIB_DIR)/libvg.a $(UNITTEST_OBJ) $(SUBCOMMAND_OBJ) $(CONFIGURATION_OBJ) $(DEPS) $(LINK_DEPS)
	-rm -f $(LIB_DIR)/vg_is_static
	. ./source_me.sh && $(CXX) $(INCLUDE_FLAGS) $(CXXFLAGS) -o $(BIN_DIR)/$(EXE) $(OBJ_DIR)/main.o $(UNITTEST_OBJ) $(SUBCOMMAND_OBJ) $(CONFIGURATION_OBJ) -lvg $(LD_LIB_FLAGS) $(ROCKSDB_LDFLAGS)

# We keep a file that we touch on the last static build.
# If the vg linkables are newer than the last static build, we do a build
$(LIB_DIR)/vg_is_static: $(INC_DIR)/vg_environment_version.hpp $(OBJ_DIR)/main.o $(LIB_DIR)/libvg.a $(UNITTEST_OBJ) $(SUBCOMMAND_OBJ) $(CONFIGURATION_OBJ) $(DEPS) $(LINK_DEPS)
	$(CXX) $(INCLUDE_FLAGS) $(CXXFLAGS) -o $(BIN_DIR)/$(EXE) $(OBJ_DIR)/main.o $(UNITTEST_OBJ) $(SUBCOMMAND_OBJ) $(CONFIGURATION_OBJ) -lvg $(STATIC_FLAGS) $(LD_LIB_FLAGS) $(ROCKSDB_LDFLAGS)
	-touch $(LIB_DIR)/vg_is_static

# We don't want to always rebuild the static vg if no files have changed.
# But we do need to rebuild it if files have changed.
# TODO: is there a way to query the mtimes of all the files and rebuild if they changed *or* vg isn't static?
# For now we link dynamically and then link statically, if we actually need to rebuild anything.
static: $(LIB_DIR)/vg_is_static

# Make sure to strip out the symbols that make the binary 300 MB, but leave the
# symbols perf needs for profiling.
static-docker: static scripts/*
	strip -d $(BIN_DIR)/$(EXE)
	DOCKER_BUILDKIT=1 docker build . -f Dockerfile.static -t vg

$(LIB_DIR)/libvg.a: $(OBJ) $(ALGORITHMS_OBJ) $(IO_OBJ) $(DEP_OBJ) $(DEPS)
	rm -f $@
	ar rs $@ $(OBJ) $(ALGORITHMS_OBJ) $(IO_OBJ) $(DEP_OBJ)

# We have system-level deps to install
get-deps:
	sudo apt-get install -qq -y build-essential git protobuf-compiler libprotoc-dev libjansson-dev libbz2-dev libncurses5-dev automake libtool jq samtools curl unzip redland-utils librdf-dev cmake pkg-config wget bc gtk-doc-tools raptor2-utils rasqal-utils bison flex gawk libgoogle-perftools-dev liblz4-dev liblzma-dev libcairo2-dev libpixman-1-dev libffi-dev libcairo-dev libprotobuf-dev 

# And we have submodule deps to build
deps: $(DEPS)

test: $(BIN_DIR)/$(EXE) $(LIB_DIR)/libvg.a test/build_graph $(BIN_DIR)/shuf $(VCFLIB_DIR)/bin/vcf2tsv $(FASTAHACK_DIR)/fastahack $(BIN_DIR)/rapper
	. ./source_me.sh && cd test && prove -v t

docs: $(SRC_DIR)/*.cpp $(SRC_DIR)/*.hpp $(SUBCOMMAND_SRC_DIR)/*.cpp $(SUBCOMMAND_SRC_DIR)/*.hpp $(UNITTEST_SRC_DIR)/*.cpp $(UNITTEST_SRC_DIR)/*.hpp
	doxygen
	echo "View documentation at: file://$(PWD)/doc/doxygen/index.html"

# Hack to use gshuf or shuf as appropriate to the platform when testing
$(BIN_DIR)/shuf:
ifeq ($(shell uname -s),Darwin)
	ln -s `which gshuf` $(BIN_DIR)/shuf
else
	ln -s `which shuf` $(BIN_DIR)/shuf
endif

test/build_graph: test/build_graph.cpp $(LIB_DIR)/libvg.a $(SRC_DIR)/json2pb.h $(SRC_DIR)/vg.hpp
	. ./source_me.sh && $(CXX) $(INCLUDE_FLAGS) $(CXXFLAGS) -o test/build_graph test/build_graph.cpp -lvg $(LD_LIB_FLAGS) $(ROCKSDB_LDFLAGS) $(FILTER)

$(LIB_DIR)/libjemalloc.a: $(JEMALLOC_DIR)/src/*.c
	+. ./source_me.sh && cd $(JEMALLOC_DIR) && ./autogen.sh && ./configure --disable-libdl --prefix=`pwd` $(FILTER) && $(MAKE) $(FILTER) && cp -r lib/* $(CWD)/$(LIB_DIR)/ && cp -r include/* $(CWD)/$(INC_DIR)/

$(LIB_DIR)/libsdsl.a: $(SDSL_DIR)/lib/*.cpp $(SDSL_DIR)/include/sdsl/*.hpp
ifeq ($(shell uname -s),Darwin)
	+. ./source_me.sh && cd $(SDSL_DIR) && AS_INTEGRATED_ASSEMBLER=1 BUILD_PORTABLE=1 ./install.sh $(CWD) $(FILTER)
else
	+. ./source_me.sh && cd $(SDSL_DIR) && BUILD_PORTABLE=1 ./install.sh $(CWD) $(FILTER)
endif	


$(LIB_DIR)/libssw.a: $(SSW_DIR)/*.c $(SSW_DIR)/*.h
	+. ./source_me.sh && cd $(SSW_DIR) && $(MAKE) $(FILTER) && ar rs $(CWD)/$(LIB_DIR)/libssw.a ssw.o ssw_cpp.o && cp ssw_cpp.h ssw.h $(CWD)/$(LIB_DIR)

# We need to hide -Xpreprocessor -fopenmp from Snappy, at least on Mac, because
# it will drop the -Xpreprocessor and keep the -fopenmp and upset Clang.
$(LIB_DIR)/libsnappy.a: $(SNAPPY_DIR)/*.cc $(SNAPPY_DIR)/*.h
	+. ./source_me.sh && cd $(SNAPPY_DIR) && ./autogen.sh && CXXFLAGS="$(filter-out -Xpreprocessor -fopenmp,$(CXXFLAGS))" ./configure --prefix=$(CWD) $(FILTER) && CXXFLAGS="$(filter-out -Xpreprocessor -fopenmp,$(CXXFLAGS))" $(MAKE) libsnappy.la $(FILTER) && cp .libs/libsnappy.a $(CWD)/lib/ && cp snappy-c.h snappy-sinksource.h snappy-stubs-public.h snappy.h $(CWD)/include/

$(LIB_DIR)/librocksdb.a: $(LIB_DIR)/libsnappy.a $(ROCKSDB_DIR)/db/*.cc $(ROCKSDB_DIR)/db/*.h
	+. ./source_me.sh && cd $(ROCKSDB_DIR) && $(ROCKSDB_PORTABLE) DISABLE_JEMALLOC=1 $(MAKE) static_lib $(FILTER) && mv librocksdb.a $(CWD)/${LIB_DIR}/ && cp -r include/* $(CWD)/$(INC_DIR)/

$(INC_DIR)/gcsa/gcsa.h: $(LIB_DIR)/libgcsa2.a

$(LIB_DIR)/libgcsa2.a: $(LIB_DIR)/libsdsl.a $(wildcard $(GCSA2_DIR)/*.cpp) $(wildcard $(GCSA2_DIR)/include/gcsa/*.h)
ifeq ($(shell uname -s),Darwin)
	+. ./source_me.sh && cp -r $(GCSA2_DIR)/include/gcsa $(CWD)/$(INC_DIR)/ && cd $(GCSA2_DIR) && AS_INTEGRATED_ASSEMBLER=1 $(MAKE) libgcsa2.a $(FILTER) && mv libgcsa2.a $(CWD)/$(LIB_DIR)
else
	+. ./source_me.sh && cp -r $(GCSA2_DIR)/include/gcsa $(CWD)/$(INC_DIR)/ && cd $(GCSA2_DIR) && $(MAKE) libgcsa2.a $(FILTER) && mv libgcsa2.a $(CWD)/$(LIB_DIR)
endif

$(INC_DIR)/gbwt/dynamic_gbwt.h: $(LIB_DIR)/libgbwt.a

$(LIB_DIR)/libgbwt.a: $(LIB_DIR)/libsdsl.a $(wildcard $(GBWT_DIR)/*.cpp) $(wildcard $(GBWT_DIR)/include/gbwt/*.h)
ifeq ($(shell uname -s),Darwin)
	+. ./source_me.sh && cp -r $(GBWT_DIR)/include/gbwt $(CWD)/$(INC_DIR)/ && cd $(GBWT_DIR) && AS_INTEGRATED_ASSEMBLER=1 $(MAKE) $(FILTER) && mv libgbwt.a $(CWD)/$(LIB_DIR)
else
	+. ./source_me.sh && cp -r $(GBWT_DIR)/include/gbwt $(CWD)/$(INC_DIR)/ && cd $(GBWT_DIR) && $(MAKE) $(FILTER) && mv libgbwt.a $(CWD)/$(LIB_DIR)
endif

$(INC_DIR)/gbwtgraph/gbwtgraph.h: $(LIB_DIR)/libgbwtgraph.a

$(LIB_DIR)/libgbwtgraph.a: $(LIB_DIR)/libgbwt.a $(LIB_DIR)/libsdsl.a $(LIB_DIR)/libhandlegraph.a $(wildcard $(GBWTGRAPH_DIR)/*.cpp) $(wildcard $(GBWTGRAPH_DIR)/include/gbwtgraph/*.h)
ifeq ($(shell uname -s),Darwin)
	+. ./source_me.sh && cp -r $(GBWTGRAPH_DIR)/include/gbwtgraph $(CWD)/$(INC_DIR)/ && cd $(GBWTGRAPH_DIR) && AS_INTEGRATED_ASSEMBLER=1 $(MAKE) $(FILTER) && mv libgbwtgraph.a $(CWD)/$(LIB_DIR)
else
	+. ./source_me.sh && cp -r $(GBWTGRAPH_DIR)/include/gbwtgraph $(CWD)/$(INC_DIR)/ && cd $(GBWTGRAPH_DIR) && $(MAKE) $(FILTER) && mv libgbwtgraph.a $(CWD)/$(LIB_DIR)
endif

$(INC_DIR)/BooPHF.h: $(BBHASH_DIR)/BooPHF.h
	+cp $(BBHASH_DIR)/BooPHF.h $(CWD)/$(INC_DIR)

$(INC_DIR)/progress_bar.hpp: $(PROGRESS_BAR_DIR)/progress_bar.hpp
	+cp $(PROGRESS_BAR_DIR)/progress_bar.hpp $(CWD)/$(INC_DIR)

$(OBJ_DIR)/progress_bar.o: $(PROGRESS_BAR_DIR)/*.hpp $(PROGRESS_BAR_DIR)/*.cpp
	+. ./source_me.sh && cd $(PROGRESS_BAR_DIR) && $(MAKE) $(FILTER) && cp progress_bar.o $(CWD)/$(OBJ_DIR)

$(OBJ_DIR)/Fasta.o: $(FASTAHACK_DIR)/*.h $(FASTAHACK_DIR)/*.cpp
	+. ./source_me.sh && cd $(FASTAHACK_DIR) && $(MAKE) $(FILTER) && mv Fasta.o $(CWD)/$(OBJ_DIR) && cp Fasta.h $(CWD)/$(INC_DIR)

# We have this target to clean up the old Protobuf we used to have.
# We can remove it after we no longer care about building properly on a dirty
# build from vg versions that shipped Protobuf themselves.
$(LIB_DIR)/cleaned_old_protobuf_v003: $(wildcard $(LIB_DIR)/libproto*) $(wildcard $(LIB_DIR)/pkgconfig/protobuf*)
	+rm -f $(LIB_DIR)/cleaned_old_protobuf*
	+rm -f $(LIB_DIR)/libproto* $(LIB_DIR)/pkgconfig/protobuf* $(BIN_DIR)/protoc
	+rm -Rf $(INC_DIR)/google/protobuf deps/protobuf
	+touch $(LIB_DIR)/cleaned_old_protobuf_v003
	
$(LIB_DIR)/libvgio.a: $(LIB_DIR)/libhts.a $(LIB_DIR)/pkgconfig/htslib.pc $(LIB_DIR)/cleaned_old_protobuf_v003 $(LIBVGIO_DIR)/CMakeLists.txt $(LIBVGIO_DIR)/src/*.cpp $(LIBVGIO_DIR)/include/vg/io/*.hpp
	+rm -f $(CWD)/$(INC_DIR)/vg.pb.h $(CWD)/$(INC_DIR)/vg/vg.pb.h
	+rm -Rf $(CWD)/$(INC_DIR)/vg/io/
	+. ./source_me.sh && cd $(LIBVGIO_DIR) && rm -Rf CMakeCache.txt CMakeFiles *.cmake install_manifest.txt *.pb.cc *.pb.h *.a && PKG_CONFIG_PATH=$(CWD)/$(LIB_DIR)/pkgconfig:$(PKG_CONFIG_PATH) cmake -DCMAKE_PREFIX_PATH=$(CWD) -DCMAKE_LIBRARY_PATH=$(CWD)/$(LIB_DIR) -DCMAKE_INSTALL_PREFIX=$(CWD) -DCMAKE_INSTALL_LIBDIR=lib . $(FILTER) && $(MAKE) clean && VERBOSE=1 $(MAKE) $(FILTER) && $(MAKE) install 

$(LIB_DIR)/libhandlegraph.a: $(LIBHANDLEGRAPH_DIR)/src/include/handlegraph/*.hpp $(LIBHANDLEGRAPH_DIR)/src/*.cpp
	+. ./source_me.sh && cd $(LIBHANDLEGRAPH_DIR) && cmake . && $(MAKE) $(FILTER) && cp libhandlegraph.a $(CWD)/$(LIB_DIR) && cp -r src/include/handlegraph $(CWD)/$(INC_DIR)


# On Linux, libdeflate builds a .so.
# On Mac, it *still* builds an so, which is just a dylib with .so extension.
# On Mac we need to make sure to set the install name. We do that by renaming to dylib.
# We don't just leave it as .so because we need to deal with outdated .so files with no paths set.
$(LIB_DIR)/libdeflate.$(SHARED_SUFFIX): $(LIB_DIR)/libdeflate.a
	+cd $(LIBDEFLATE_DIR) && cp libdeflate.so $(CWD)/$(LIB_DIR)
	+touch $(CWD)/$(LIB_DIR)/libdeflate.so
ifeq ($(shell uname -s),Darwin)
	+mv $(LIB_DIR)/libdeflate.so $(LIB_DIR)/libdeflate.$(SHARED_SUFFIX)
	+install_name_tool -id $(CWD)/$(LIB_DIR)/libdeflate.$(SHARED_SUFFIX) $(LIB_DIR)/libdeflate.$(SHARED_SUFFIX)
endif

$(LIB_DIR)/libdeflate.a: $(LIBDEFLATE_DIR)/*.h $(LIBDEFLATE_DIR)/lib/*.h $(LIBDEFLATE_DIR)/lib/*/*.h $(LIBDEFLATE_DIR)/lib/*.c $(LIBDEFLATE_DIR)/lib/*/*.c
	+. ./source_me.sh && cd $(LIBDEFLATE_DIR) && V=1 $(MAKE) $(FILTER) && cp libdeflate.a $(CWD)/$(LIB_DIR) && cp libdeflate.h $(CWD)/$(INC_DIR)

# We build htslib after libdeflate so it can use libdeflate
# We have to do a full build in order to install, to get the pkg-config file so libvgio can link against it.
# We also have to have the shared libdeflate or we will get complaints that the static one is not position independent.
# If we need either the library or the pkg-config file (which we didn't used to ship), run the whole build.
# We use a wildcard match to make sure make understands that both files come from one command run.
# See https://stackoverflow.com/a/3077254
$(LIB_DIR)/libhts%a $(LIB_DIR)/pkgconfig/htslib%pc: $(LIB_DIR)/libdeflate.a $(LIB_DIR)/libdeflate.$(SHARED_SUFFIX) $(HTSLIB_DIR)/*.c $(HTSLIB_DIR)/*.h $(HTSLIB_DIR)/htslib/*.h $(HTSLIB_DIR)/cram/*.c $(HTSLIB_DIR)/cram/*.h
	+. ./source_me.sh && cd $(HTSLIB_DIR) && rm -Rf $(CWD)/$(INC_DIR)/htslib $(CWD)/$(LIB_DIR)/libhts* && autoheader && autoconf && CFLAGS="-I$(CWD)/$(INC_DIR)" LDFLAGS="-L$(CWD)/$(LIB_DIR)" ./configure --with-libdeflate --disable-s3 --disable-gcs --disable-libcurl --disable-plugins --prefix=$(CWD) $(FILTER) && $(MAKE) clean && $(MAKE) $(FILTER) && $(MAKE) install

# We tell the vcflib build to use our own htslib.
# We link it and libdeflate statically (on Linux) because our lib directory won't
# necessarily be on the vcflib binaries' search path.
$(LIB_DIR)/libvcflib.a: $(LIB_DIR)/libhts.a $(VCFLIB_DIR)/src/*.cpp $(VCFLIB_DIR)/src/*.hpp $(VCFLIB_DIR)/intervaltree/*.cpp $(VCFLIB_DIR)/intervaltree/*.h $(VCFLIB_DIR)/tabixpp/*.cpp $(VCFLIB_DIR)/tabixpp/*.hpp
	+. ./source_me.sh && cd $(VCFLIB_DIR) && $(MAKE) clean && HTS_LIB="$(CWD)/$(LIB_DIR)/libhts.a" HTS_INCLUDES="-I$(CWD)/$(INC_DIR)" HTS_LDFLAGS="-L$(CWD)/$(LIB_DIR) $(START_STATIC) -lhts -ldeflate $(END_STATIC) -lpthread -lm -lbz2 -llzma -lz" $(MAKE) libvcflib.a $(FILTER) && cp lib/* $(CWD)/$(LIB_DIR)/ && cp include/* $(CWD)/$(INC_DIR)/ && cp intervaltree/*.h $(CWD)/$(INC_DIR)/ && cp src/*.h* $(CWD)/$(INC_DIR)/

$(VCFLIB_DIR)/bin/vcf2tsv: $(VCFLIB_DIR)/src/*.cpp $(VCFLIB_DIR)/src/*.h $(LIB_DIR)/libvcflib.a
	+. ./source_me.sh && cd $(VCFLIB_DIR) && HTS_LIB="$(CWD)/$(LIB_DIR)/libhts.a" HTS_INCLUDES="-I$(CWD)/$(INC_DIR)" HTS_LDFLAGS="-L$(CWD)/$(LIB_DIR) $(START_STATIC) -lhts -ldeflate $(END_STATIC) -lpthread -lm -lbz2 -llzma -lz" $(MAKE) vcf2tsv $(FILTER)

$(FASTAHACK_DIR)/fastahack: $(FASTAHACK_DIR)/*.c $(FASTAHACK_DIR)/*.h $(FASTAHACK_DIR)/*.cpp
	+. ./source_me.sh && cd $(FASTAHACK_DIR) && $(MAKE) $(FILTER)

$(LIB_DIR)/libgssw.a: $(GSSW_DIR)/src/gssw.c $(GSSW_DIR)/src/gssw.h
	+. ./source_me.sh && cd $(GSSW_DIR) && $(MAKE) $(FILTER) && cp lib/* $(CWD)/$(LIB_DIR)/ && cp obj/* $(CWD)/$(OBJ_DIR) && cp src/*.h $(CWD)/$(INC_DIR)

$(INC_DIR)/lru_cache.h: $(DEP_DIR)/lru_cache/*.h $(DEP_DIR)/lru_cache/*.cc
	+cd $(DEP_DIR)/lru_cache && cp *.h* $(CWD)/$(INC_DIR)/

# We moved the Dynamic headers so make sure to clean up the old ones.
$(INC_DIR)/dynamic/dynamic.hpp: $(DYNAMIC_DIR)/include/*.hpp $(DYNAMIC_DIR)/include/internal/*.hpp
	rm -Rf $(INC_DIR)/dynamic.hpp $(INC_DIR)/dynamic
	mkdir -p $(INC_DIR)/dynamic && cp -r $(CWD)/$(DYNAMIC_DIR)/include/* $(INC_DIR)/dynamic
	# annoyingly doesn't have an install option on the cmake, so we manually move their external dependency headers
	cd $(CWD)/$(DYNAMIC_DIR) && mkdir -p build && cd build && cmake .. && make && cp -r hopscotch_map-prefix/src/hopscotch_map/include/* $(CWD)/$(INC_DIR)/dynamic

$(INC_DIR)/sparsehash/sparse_hash_map: $(wildcard $(SPARSEHASH_DIR)/**/*.cc) $(wildcard $(SPARSEHASH_DIR)/**/*.h) 
	+. ./source_me.sh && cd $(SPARSEHASH_DIR) && ./autogen.sh && LDFLAGS="-L/opt/local/lib" ./configure --prefix=$(CWD) $(FILTER) && $(MAKE) $(FILTER) && $(MAKE) install

$(INC_DIR)/sparsepp/spp.h: $(wildcard $(SPARSEHASH_DIR)/sparsepp/*.h)
	+cp -r $(SPARSEPP_DIR)/sparsepp $(INC_DIR)/

#$(INC_DIR)/Variant.h
$(LIB_DIR)/libvcfh.a: $(DEP_DIR)/libVCFH/*.cpp $(DEP_DIR)/libVCFH/*.hpp 
	+. ./source_me.sh && cd $(DEP_DIR)/libVCFH && $(MAKE) $(FILTER) && cp libvcfh.a $(CWD)/$(LIB_DIR)/ && cp vcfheader.hpp $(CWD)/$(INC_DIR)/

$(INC_DIR)/gfakluge.hpp: $(DEP_DIR)/gfakluge/src/gfakluge.hpp
	+cp $(DEP_DIR)/gfakluge/src/*.hpp $(CWD)/$(INC_DIR)/ && cp $(DEP_DIR)/gfakluge/src/tinyFA/*.hpp $(CWD)/$(INC_DIR)/

$(LIB_DIR)/libsonlib.a: $(CWD)/$(DEP_DIR)/sonLib/C/inc/*.h $(CWD)/$(DEP_DIR)/sonLib/C/impl/*.c
	+. ./source_me.sh && cd $(DEP_DIR)/sonLib && kyotoTycoonLib="" $(MAKE) $(FILTER) && cp lib/sonLib.a $(CWD)/$(LIB_DIR)/libsonlib.a && mkdir -p $(CWD)/$(INC_DIR)/sonLib && cp lib/*.h $(CWD)/$(INC_DIR)/sonLib

$(LIB_DIR)/libpinchesandcacti.a: $(LIB_DIR)/libsonlib.a $(CWD)/$(DEP_DIR)/pinchesAndCacti/inc/*.h $(CWD)/$(DEP_DIR)/pinchesAndCacti/impl/*.c
	+. ./source_me.sh && cd $(DEP_DIR)/pinchesAndCacti && $(MAKE) $(FILTER) && cd $(CWD)/$(DEP_DIR)/sonLib && cp lib/stPinchesAndCacti.a $(CWD)/$(LIB_DIR)/libpinchesandcacti.a && cp lib/3EdgeConnected.a $(CWD)/$(LIB_DIR)/lib3edgeconnected.a && mkdir -p $(CWD)/$(INC_DIR)/sonLib && cp lib/*.h $(CWD)/$(INC_DIR)/sonLib

# When building raptor we need to make sure to pre-generate and fix up the lexer
# We also need to clear out its cmake stuff in case it found a wrong Bison and cached it.
$(LIB_DIR)/libraptor2.a: $(RAPTOR_DIR)/src/* $(wildcard $(RAPTOR_DIR)/build/*)
	which bison
	+. ./source_me.sh && cd $(RAPTOR_DIR)/build && rm -Rf CMakeCache.txt CMakeFiles CTestTestfile.cmake Makefile cmake_install.cmake src tests utils && cmake .. && rm -f src/turtle_parser.c && rm -f src/turtle_lexer.c && make turtle_lexer_tgt && make -f src/CMakeFiles/raptor2.dir/build.make src/turtle_lexer.c && sed -i.bak '/yycleanup/d' src/turtle_lexer.c && $(MAKE) $(FILTER) && cp src/libraptor2.a $(CWD)/$(LIB_DIR)
	+touch $(LIB_DIR)/libraptor2.a

# We need rapper from Raptor for the tests
$(BIN_DIR)/rapper: $(LIB_DIR)/libraptor2.a
	+cp $(RAPTOR_DIR)/build/utils/rapper $(BIN_DIR)/

# The Raptor header needs to be newer than the library.
# Mac Travis managed to get an old header with a new binary.
$(INC_DIR)/raptor2/raptor2.h: $(LIB_DIR)/libraptor2.a $(RAPTOR_DIR)/build/*
	+cd $(RAPTOR_DIR)/build && mkdir -p $(CWD)/$(INC_DIR)/raptor2 && cp src/*.h $(CWD)/$(INC_DIR)/raptor2
	+touch $(INC_DIR)/raptor2/raptor2.h

$(LIB_DIR)/libstructures.a: $(STRUCTURES_DIR)/src/include/structures/*.hpp $(STRUCTURES_DIR)/src/*.cpp $(STRUCTURES_DIR)/Makefile 
	+. ./source_me.sh && cd $(STRUCTURES_DIR) && $(MAKE) clean && $(MAKE) lib/libstructures.a $(FILTER) && cp lib/libstructures.a $(CWD)/$(LIB_DIR)/ && cp -r src/include/structures $(CWD)/$(INC_DIR)/

# To build libvw we need to point it at our Boost, but then configure decides
# it needs to build vwdll, which depends on codecvt, which isn't actually
# shipped in the GCC 4.9 STL. So we hack vwdll AKA libvw_c_wrapper out of the
# build.
# Also, autogen.sh looks for Boost in the system, and who knows what it will do
# if it doesn't find it, so let it fail.
# Also, we need to make sure nothing about -fopenmp makes it into the build, in case we are on Clang.
# vw doesn't need OpenMP
$(LIB_DIR)/libvw.a: $(LIB_DIR)/libboost_program_options.a $(VOWPALWABBIT_DIR)/* $(VOWPALWABBIT_DIR)/vowpalwabbit/*
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && sed -i -e 's/libvw_c_wrapper\.pc//g' Makefile.am
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && sed -i -e 's/libvw_c_wrapper\.la//g' vowpalwabbit/Makefile.am
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && sed -i -e '/libvw_c_wrapper\.pc/d' configure.ac
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && sed -i -e '/vwdll/d' Makefile.am
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && sed -i -e '/libvw_c_wrapper/d' vowpalwabbit/Makefile.am
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && CXXFLAGS="$(filter-out -Xpreprocessor -fopenmp,$(CXXFLAGS))" ./autogen.sh || true
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && CXXFLAGS="$(filter-out -Xpreprocessor -fopenmp,$(CXXFLAGS))" ./configure --with-boost=$(CWD)
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && CXXFLAGS="$(filter-out -Xpreprocessor -fopenmp,$(CXXFLAGS))" $(MAKE) $(FILTER)
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && cp vowpalwabbit/.libs/libvw.a vowpalwabbit/.libs/liballreduce.a $(CWD)/$(LIB_DIR)/
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && mkdir -p $(CWD)/$(INC_DIR)/vowpalwabbit
	+. ./source_me.sh && cd $(VOWPALWABBIT_DIR) && cp vowpalwabbit/*.h $(CWD)/$(INC_DIR)/vowpalwabbit/

$(LIB_DIR)/liballreduce.a: $(LIB_DIR)/libvw.a

# Building Boost with GCC against libc++ on Mac doesn't work. See https://travis-ci.org/vgteam/vg/jobs/583377358
# So on Mac we make sure to always use Clang, even if the rest of the build uses GCC.
# See https://gist.github.com/jimporter/10442880
$(LIB_DIR)/libboost_program_options.a: $(BOOST_DIR)/libs/program_options/src/* $(BOOST_DIR)/boost/program_options/*
ifeq ($(shell uname -s),Darwin)
	+. ./source_me.sh && cd $(BOOST_DIR) && ./bootstrap.sh --with-libraries=program_options --libdir=$(CWD)/$(LIB_DIR) --includedir=$(CWD)/$(INC_DIR) $(FILTER) && ./b2 --ignore-site-config --link=static toolset=clang cxxflags="-std=c++1y -stdlib=libc++" linkflags="-stdlib=libc++" install $(FILTER)
	+. ./source_me.sh && install_name_tool -id $(CWD)/$(LIB_DIR)/libboost_program_options.dylib $(CWD)/$(LIB_DIR)/libboost_program_options.dylib
else
	+. ./source_me.sh && cd $(BOOST_DIR) && ./bootstrap.sh --with-libraries=program_options --libdir=$(CWD)/$(LIB_DIR) --includedir=$(CWD)/$(INC_DIR) $(FILTER) && ./b2 --ignore-site-config --link=static cxxflags="$(CXXFLAGS)" linkflags="$(CXXFLAGS)" install $(FILTER)
endif

$(INC_DIR)/sha1.hpp: $(SHA1_DIR)/sha1.hpp
	+cp $(SHA1_DIR)/*.h* $(CWD)/$(INC_DIR)/

$(INC_DIR)/backward.hpp: $(BACKWARD_CPP_DIR)/backward.hpp
	+cp $(BACKWARD_CPP_DIR)/backward.hpp $(CWD)/$(INC_DIR)/

$(INC_DIR)/dozeu/dozeu.h: $(DOZEU_DIR)/*.h
	+mkdir -p $(CWD)/$(INC_DIR)/dozeu && cp $(DOZEU_DIR)/*.h $(CWD)/$(INC_DIR)/dozeu/

$(LIB_DIR)/libebl.a: $(LIB_DIR)/libelf.a

$(LIB_DIR)/libdw.a: $(LIB_DIR)/libelf.a

$(LIB_DIR)/libdwelf.a: $(LIB_DIR)/libelf.a

$(LIB_DIR)/libdwfl.a: $(LIB_DIR)/libelf.a

# We can't build elfutils from Git without "maintainer mode".
# There are some release-only headers or something that it complains it can't find otherwise.
# We also don't do a normal make and make install here because we don't want to build and install all the elfutils binaries and libasm.
$(LIB_DIR)/libelf.a: $(ELFUTILS_DIR)/libebl/*.c $(ELFUTILS_DIR)/libebl/*.h $(ELFUTILS_DIR)/libdw/*.c $(ELFUTILS_DIR)/libdw/*.h $(ELFUTILS_DIR)/libelf/*.c $(ELFUTILS_DIR)/libelf/*.h $(ELFUTILS_DIR)/src/*.c $(ELFUTILS_DIR)/src/*.h
	+cd $(CWD)/$(INC_DIR)/ && rm -Rf elfutils gelf.h libelf.h dwarf.h libdwflP.h libdwfl.h libebl.h libelf.h
	+. ./source_me.sh && cd $(ELFUTILS_DIR) && autoreconf -i -f && ./configure --enable-maintainer-mode --prefix=$(CWD) $(FILTER)
	+. ./source_me.sh && cd $(ELFUTILS_DIR)/libelf && $(MAKE) clean && $(MAKE) libelf.a $(FILTER)
	+. ./source_me.sh && cd $(ELFUTILS_DIR)/libebl && $(MAKE) clean && $(MAKE) libebl.a $(FILTER)
	+. ./source_me.sh && cd $(ELFUTILS_DIR)/libdwfl && $(MAKE) clean && $(MAKE) libdwfl.a $(FILTER)
	+. ./source_me.sh && cd $(ELFUTILS_DIR)/libdwelf && $(MAKE) clean && $(MAKE) libdwelf.a $(FILTER)
	+. ./source_me.sh && cd $(ELFUTILS_DIR)/libdw && $(MAKE) clean && $(MAKE) libdw.a known-dwarf.h $(FILTER)
	+cd $(ELFUTILS_DIR) && mkdir -p $(CWD)/$(INC_DIR)/elfutils && cp libdw/known-dwarf.h libdw/libdw.h libebl/libebl.h libelf/elf-knowledge.h version.h libdwfl/libdwfl.h libdwelf/libdwelf.h $(CWD)/$(INC_DIR)/elfutils && cp libelf/gelf.h libelf/libelf.h libdw/dwarf.h $(CWD)/$(INC_DIR) && cp libebl/libebl.a libdw/libdw.a libdwfl/libdwfl.a libdwelf/libdwelf.a libelf/libelf.a $(CWD)/$(LIB_DIR)/

$(OBJ_DIR)/sha1.o: $(SHA1_DIR)/sha1.cpp $(SHA1_DIR)/sha1.hpp
	+$(CXX) $(INCLUDE_FLAGS) $(CXXFLAGS) -c -o $@ $< $(FILTER)

$(LIB_DIR)/libfml.a: $(FERMI_DIR)/*.h $(FERMI_DIR)/*.c
	. ./source_me.sh && cd $(FERMI_DIR) && $(MAKE) $(FILTER) && cp *.h $(CWD)/$(INC_DIR)/ && cp libfml.a $(CWD)/$(LIB_DIR)/

# We don't need to hack the build to point at our htslib because sublinearLS gets its htslib from the include flags we set
$(LIB_DIR)/libsublinearLS.a: $(LINLS_DIR)/src/*.cpp $(LINLS_DIR)/src/*.hpp $(LIB_DIR)/libhts.a
	. ./source_me.sh && cd $(LINLS_DIR) && $(MAKE) clean && INCLUDE_FLAGS="-I$(CWD)/$(INC_DIR)" $(MAKE) libs $(FILTER) && cp lib/libsublinearLS.a $(CWD)/$(LIB_DIR)/ && mkdir -p $(CWD)/$(INC_DIR)/sublinearLS && cp src/*.hpp $(CWD)/$(INC_DIR)/sublinearLS/

$(LIB_DIR)/libbdsg.a: $(INC_DIR)/BooPHF.h $(LIBBDSG_DIR)/src/*.cpp $(LIBBDSG_DIR)/include/bdsg/*.hpp $(LIB_DIR)/libhandlegraph.a $(LIB_DIR)/libsdsl.a $(INC_DIR)/sparsepp/spp.h $(INC_DIR)/dynamic/dynamic.hpp
	+. ./source_me.sh  && cd $(LIBBDSG_DIR) && $(MAKE) clean && CPLUS_INCLUDE_PATH=$(CWD)/$(INC_DIR):$(CWD)/$(INC_DIR)/dynamic:$(CPLUS_INCLUDE_PATH) $(MAKE) $(FILTER) && cp lib/libbdsg.a $(CWD)/$(LIB_DIR) && pwd && cp -r include/bdsg $(CWD)/$(INC_DIR)

$(INC_DIR)/mmmultiset.hpp: $(MMMULTIMAP_DIR)/src/mmmultiset.hpp $(INC_DIR)/mmmultimap.hpp
$(INC_DIR)/mmmultimap.hpp: $(MMMULTIMAP_DIR)/src/mmmultimap.hpp $(MMMULTIMAP_DIR)/src/mmmultiset.hpp
	+. ./source_me.sh && cp $(MMMULTIMAP_DIR)/src/mmmultimap.hpp $(MMMULTIMAP_DIR)/src/mmmultiset.hpp $(CWD)/$(INC_DIR)/

$(INC_DIR)/ips4o.hpp: $(IPS4O_DIR)/ips4o.hpp $(IPS4O_DIR)/ips4o/*
	+. ./source_me.sh && cp -r $(IPS4O_DIR)/ips4o* $(CWD)/$(INC_DIR)/

# The xg repo has a cmake build system based all around external projects, and
# we need it to use our installed versions of everything instead.
$(LIB_DIR)/libxg.a: $(XG_DIR)/src/*.hpp $(XG_DIR)/src/*.cpp $(INC_DIR)/mmmultimap.hpp $(INC_DIR)/ips4o.hpp $(INC_DIR)/gfakluge.hpp $(LIB_DIR)/libhandlegraph.a $(LIB_DIR)/libsdsl.a
	+rm -f $@
	+cp -r $(XG_DIR)/src/*.hpp $(CWD)/$(INC_DIR)
	+. ./source_me.sh && $(CXX) $(INCLUDE_FLAGS) $(CXXFLAGS) -c -o $(XG_DIR)/xg.o $(XG_DIR)/src/xg.cpp $(FILTER)
	+ar rs $@ $(XG_DIR)/xg.o

# Auto-git-versioning

# We need to scope this variable here
GIT_VERSION_FILE_DEPS =
# Decide if .git exists and needs to be watched
ifeq ($(shell if [ -d .git ]; then echo present; else echo absent; fi),present)
    # If so, try and make a git version file
	GIT_VERSION_FILE_DEPS = .check-git
else
    # Just use the version file we have, if any
	GIT_VERSION_FILE_DEPS = .no-git
endif

# Build a real git version file.
# If it's not the same as the old one, replace the old one.
# If it is the same, do nothing and don't rebuild dependent targets.
.check-git:
	@echo "#define VG_GIT_VERSION \"$(shell git describe --always --tags 2>/dev/null || echo git-error)\"" > $(INC_DIR)/vg_git_version.hpp.tmp
	@diff $(INC_DIR)/vg_git_version.hpp.tmp $(INC_DIR)/vg_git_version.hpp >/dev/null || cp $(INC_DIR)/vg_git_version.hpp.tmp $(INC_DIR)/vg_git_version.hpp
	@rm -f $(INC_DIR)/vg_git_version.hpp.tmp

# Make sure the version file exists, if we weren't given one in our tarball
.no-git:
	@if [ ! -e $(INC_DIR)/vg_git_version.hpp ]; then \
		touch $(INC_DIR)/vg_git_version.hpp; \
	fi;

$(INC_DIR)/vg_git_version.hpp: $(GIT_VERSION_FILE_DEPS)
# Build an environment version file with this phony target.
# If it's not the same as the old one, replace the old one.
# If it is the same, do nothing and don't rebuild dependent targets.
.check-environment:
	@echo "#define VG_COMPILER_VERSION \"$(shell $(CXX) --version 2>/dev/null | head -n 1)\"" > $(INC_DIR)/vg_environment_version.hpp.tmp
	@echo "#define VG_OS \"$(shell uname)\"" >> $(INC_DIR)/vg_environment_version.hpp.tmp
	@echo "#define VG_BUILD_USER \"$(shell whoami)\"" >> $(INC_DIR)/vg_environment_version.hpp.tmp
	@echo "#define VG_BUILD_HOST \"$(shell hostname)\"" >> $(INC_DIR)/vg_environment_version.hpp.tmp
	@diff $(INC_DIR)/vg_environment_version.hpp.tmp $(INC_DIR)/vg_environment_version.hpp >/dev/null || cp $(INC_DIR)/vg_environment_version.hpp.tmp $(INC_DIR)/vg_environment_version.hpp
	@rm -f $(INC_DIR)/vg_environment_version.hpp.tmp

# The way to get the actual file is to maybe replace it.
$(INC_DIR)/vg_environment_version.hpp: .check-environment

###################################
## VG source code compilation begins here
####################################

$(OBJ_DIR)/version.o: $(SRC_DIR)/version.cpp $(SRC_DIR)/version.hpp $(INC_DIR)/vg_git_version.hpp $(INC_DIR)/vg_environment_version.hpp

########################
## Pattern Rules
########################

# Define a default rule for building objects from CPP files
# Depend on the .d file so we rebuild if dependency info is missing/deleted
# Make sure to touch the .o file after the compiler finishes so it is always newer than the .d file
# Use static pattern rules so the dependency files will not be ignored if the output exists
# See <https://stackoverflow.com/a/34983297>
$(OBJ) $(CONFIGURATION_OBJ) $(OBJ_DIR)/main.o: $(OBJ_DIR)/%.o : $(SRC_DIR)/%.cpp $(OBJ_DIR)/%.d $(DEPS)
	. ./source_me.sh && $(CXX) $(INCLUDE_FLAGS) $(CXXFLAGS) -c -o $@ $< $(FILTER)
	@touch $@
$(ALGORITHMS_OBJ): $(ALGORITHMS_OBJ_DIR)/%.o : $(ALGORITHMS_SRC_DIR)/%.cpp $(ALGORITHMS_OBJ_DIR)/%.d $(DEPS)
	. ./source_me.sh && $(CXX) $(INCLUDE_FLAGS) $(CXXFLAGS) -c -o $@ $< $(FILTER)
	@touch $@
$(IO_OBJ): $(IO_OBJ_DIR)/%.o : $(IO_SRC_DIR)/%.cpp $(IO_OBJ_DIR)/%.d $(DEPS)
	. ./source_me.sh && $(CXX) $(INCLUDE_FLAGS) $(CXXFLAGS) -c -o $@ $< $(FILTER)
	@touch $@
$(SUBCOMMAND_OBJ): $(SUBCOMMAND_OBJ_DIR)/%.o : $(SUBCOMMAND_SRC_DIR)/%.cpp $(SUBCOMMAND_OBJ_DIR)/%.d $(DEPS)
	. ./source_me.sh && $(CXX) $(INCLUDE_FLAGS) $(CXXFLAGS) -c -o $@ $< $(FILTER)
	@touch $@
$(UNITTEST_OBJ): $(UNITTEST_OBJ_DIR)/%.o : $(UNITTEST_SRC_DIR)/%.cpp $(UNITTEST_OBJ_DIR)/%.d $(DEPS)
	. ./source_me.sh && $(CXX) $(INCLUDE_FLAGS) $(CXXFLAGS) -c -o $@ $< $(FILTER)
	@touch $@

# Use a fake rule to build .d files, so we don't complain if they don't exist.
$(OBJ_DIR)/%.d: ;
$(ALGORITHMS_OBJ_DIR)/%.d: ;
$(IO_OBJ_DIR)/%.d: ;
$(SUBCOMMAND_OBJ_DIR)/%.d: ;
$(UNITTEST_OBJ_DIR)/%.d: ;

# Don't delete them.
.PRECIOUS: $(OBJ_DIR)/%.d $(ALGORITHMS_OBJ_DIR)/%.d $(IO_OBJ_DIR)/%.d $(SUBCOMMAND_OBJ_DIR)/%.d $(UNITTEST_OBJ_DIR)/%.d

# Use no implicit rules
.SUFFIXES:

###################################
## VG source code compilation ends here
####################################



.pre-build:
	@if [ ! -d $(BIN_DIR) ]; then mkdir -p $(BIN_DIR); fi
	@if [ ! -d $(LIB_DIR) ]; then mkdir -p $(LIB_DIR); fi
	@if [ ! -d $(OBJ_DIR) ]; then mkdir -p $(OBJ_DIR); fi
	@if [ ! -d $(ALGORITHMS_OBJ_DIR) ]; then mkdir -p $(ALGORITHMS_OBJ_DIR); fi
	@if [ ! -d $(IO_OBJ_DIR) ]; then mkdir -p $(IO_OBJ_DIR); fi
	@if [ ! -d $(SUBCOMMAND_OBJ_DIR) ]; then mkdir -p $(SUBCOMMAND_OBJ_DIR); fi
	@if [ ! -d $(UNITTEST_OBJ_DIR) ]; then mkdir -p $(UNITTEST_OBJ_DIR); fi
	@if [ ! -d $(INC_DIR) ]; then mkdir -p $(INC_DIR); fi

# run .pre-build before we make anything at all.
-include .pre-build

# for rebuilding just vg
clean-vg:
	$(RM) -r $(BIN_DIR)/$(EXE)
	$(RM) -r $(UNITTEST_OBJ_DIR)/*.o $(UNITTEST_OBJ_DIR)/*.d
	$(RM) -r $(SUBCOMMAND_OBJ_DIR)/*.o $(SUBCOMMAND_OBJ_DIR)/*.d
	$(RM) -r $(OBJ_DIR)/*.o $(OBJ_DIR)/*.d
	$(RM) -f $(INC_DIR)/vg_git_version.hpp $(INC_DIR)/vg_system_version.hpp

clean: clean-rocksdb clean-vcflib
	$(RM) -r $(BIN_DIR)
	$(RM) -r $(LIB_DIR)
	$(RM) -r $(UNITTEST_OBJ_DIR)
	$(RM) -r $(SUBCOMMAND_OBJ_DIR)
	$(RM) -r $(IO_OBJ_DIR)
	$(RM) -r $(ALGORITHMS_OBJ_DIR)
	$(RM) -r $(OBJ_DIR)
	$(RM) -r $(INC_DIR)
	$(RM) -r share/
	cd $(DEP_DIR) && cd sonLib && $(MAKE) clean
	cd $(DEP_DIR) && cd sparsehash && $(MAKE) clean
	cd $(DEP_DIR) && cd htslib && $(MAKE) clean
	cd $(DEP_DIR) && cd fastahack && $(MAKE) clean
	cd $(DEP_DIR) && cd gcsa2 && $(MAKE) clean
	cd $(DEP_DIR) && cd gbwt && $(MAKE) clean
	cd $(DEP_DIR) && cd gbwtgraph && $(MAKE) clean
	cd $(DEP_DIR) && cd gssw && $(MAKE) clean
	cd $(DEP_DIR) && cd ssw && cd src && $(MAKE) clean
	cd $(DEP_DIR) && cd progress_bar && $(MAKE) clean
	cd $(DEP_DIR) && cd sdsl-lite && ./uninstall.sh || true
	cd $(DEP_DIR) && cd libVCFH && $(MAKE) clean
	cd $(DEP_DIR) && cd vcflib && $(MAKE) clean
	cd $(DEP_DIR) && cd gfakluge && $(MAKE) clean
	cd $(DEP_DIR) && cd sha1 && $(MAKE) clean
	cd $(DEP_DIR) && cd structures && $(MAKE) clean
	cd $(DEP_DIR) && cd jemalloc && $(MAKE) clean || true
	cd $(DEP_DIR) && cd vowpal_wabbit && $(MAKE) clean
	cd $(DEP_DIR) && cd sublinear-Li-Stephens && $(MAKE) clean
	cd $(DEP_DIR) && cd libhandlegraph && $(MAKE) clean
	cd $(DEP_DIR) && cd libvgio && $(MAKE) clean 
	cd $(DEP_DIR) && cd raptor && cd build && find . -not \( -name '.gitignore' -or -name 'pkg.m4' \) -delete
    # lru_cache is never built because it is header-only
    # bash-tap is never built either

clean-rocksdb:
	cd $(DEP_DIR) && cd rocksdb && $(MAKE) clean
	rm -f $(LIB_DIR)/librocksdb.a 
	rm -rf $(INC_DIR)/rocksdb/

clean-vcflib:
	cd $(DEP_DIR) && cd vcflib && $(MAKE) clean
	rm -f $(LIB_DIR)/libvcfh.a
	cd $(INC_DIR) && rm -f BedReader.h convert.h join.h mt19937ar.h split.h Variant.h vec128int.h veclib_types.h
