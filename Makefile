# WARNING: This makefile is intended to be invoked by LuaRocks, not manually.

# Disable all default build rules so that we have full control.
.SUFFIXES:

################################################################################
# DEFAULTS
# These are only used when this Makefile is run manually. You should only be
# doing that for `make clean`. Use `luarocks` for everything else.

CURL = curl
LIB_EXTENSION = so
LUA = lua
LUA_DIR = /usr/local
LUAROCKS = luarocks
MKDIR = mkdir
OBJ_EXTENSION = o
UNICORN_INCDIR = /usr/include

################################################################################

# Disable 64-bit integer tests for Lua <5.3
LUA_VERSION = $(shell $(LUA) -e 'print(_VERSION:sub(5))')
ifeq ($(LUA_VERSION),5.1)
    BUSTED_FLAGS = --exclude-tags="int64only"
else ifeq ($(LUA_VERSION),5.2)
    BUSTED_FLAGS = --exclude-tags="int64only"
else
    BUSTED_FLAGS =
endif


IS_LUAJIT = $(shell $(LUA) -e 'if _G.jit ~= nil then print(1) else print(0) end')
ifeq ($(IS_LUAJIT),1)
    # LuaJIT
    DEFAULT_LUA_LIB_NAME = luajit-$(LUA_VERSION)
    LUAJIT_VERSION = $(shell \
        $(LUA) -e 'print(string.format("%d.%d", jit.version_num / 10000, (jit.version_num / 100) % 100))' \
    )
    FALLBACK_LUA_INCDIR = $(LUA_DIR)/include/luajit-$(LUAJIT_VERSION)
else
    # Regular Lua
    DEFAULT_LUA_LIB_NAME = lua
    FALLBACK_LUA_INCDIR = $(LUA_DIR)/include
endif

BUILD_DIR = $(CURDIR)/build

ARCHITECTURE_HEADERS = $(wildcard $(UNICORN_INCDIR)/unicorn/*.h)
ARCHITECTURE_SLUGS = $(filter-out platform,$(basename $(notdir $(ARCHITECTURE_HEADERS))))

CONSTS_DIR = src/constants
CONSTANT_FILES = $(foreach s,$(ARCHITECTURE_SLUGS),$(CONSTS_DIR)/$(s)_const.cpp)

CPP_TEMPLATE_SOURCES = $(wildcard src/*.template)
AUTOGENERATED_CPP_FILES = $(CPP_TEMPLATE_SOURCES:.template=.cpp)

HEADER_TEMPLATE_SOURCES = $(wildcard include/unicornlua/*.template)
AUTOGENERATED_HPP_FILES = $(HEADER_TEMPLATE_SOURCES:.template=.hpp)

LIB_BUILD_TARGET = $(BUILD_DIR)/unicorn.$(LIB_EXTENSION)
LIB_CPP_SOURCES = $(wildcard src/*.cpp) $(CONSTANT_FILES) $(AUTOGENERATED_CPP_FILES)
LIB_OBJECT_FILES = $(LIB_CPP_SOURCES:.cpp=.$(OBJ_EXTENSION))

TEST_EXECUTABLE = $(BUILD_DIR)/cpp_test
TEST_CPP_SOURCES = $(wildcard tests/c/*.cpp)
TEST_LUA_SOURCES = $(wildcard tests/lua/*.lua)
TEST_HEADERS = $(wildcard tests/c/*.hpp)
TEST_CPP_OBJECT_FILES = $(TEST_CPP_SOURCES:.cpp=.$(OBJ_EXTENSION))

TEMPLATE_DATA_FILES = $(wildcard src/template_data/*.lua)

LIBRARY_DIRECTORIES = $(strip $(LUA_LIBDIR) $(UNICORN_LIBDIR) $(PTHREAD_LIBDIR) /usr/lib64 /usr/local/lib)
HEADER_DIRECTORIES = $(strip $(CURDIR)/include $(LUA_INCDIR) $(FALLBACK_LUA_INCDIR) $(UNICORN_INCDIR) /usr/local/include)

ifndef USER_CXX_FLAGS
    USER_CXX_FLAGS =
endif
OTHER_CXXFLAGS = -std=c++11 -DIS_LUAJIT=$(IS_LUAJIT)
WARN_FLAGS = -Wall -Wextra -Werror -Wpedantic -pedantic-errors
INCLUDE_PATH_FLAGS = $(addprefix -I,$(HEADER_DIRECTORIES))
LIB_PATH_FLAGS = $(addprefix -L,$(LIBRARY_DIRECTORIES))
REQUIRED_LIBS = unicorn pthread stdc++
REQUIRED_LIBS_FLAGS = $(addprefix -l,$(REQUIRED_LIBS))

# LUALIB isn't always provided. This breaks building our tests on LuaJIT, which
# uses a filename other than liblua.a for its library. Thus, -llua won't work on
# LuaJIT (any platform) or Windows (any Lua version).
LINK_TO_LUA_FLAG = $(if $(LUALIB),-l:$(LUALIB),-l$(DEFAULT_LUA_LIB_NAME))

# https://github.com/PowerDNS/pdns/issues/4295
ifndef OS
    OS = $(shell uname -s)
endif

ifeq ($(OS),Darwin)
    ifeq ($(IS_LUAJIT),1)
        # This workaround isn't needed for LuaJIT 2.1+
        ifeq ($(LUAJIT_VERSION),2.0)
            LINK_TO_LUA_FLAG += -pagezero_size 10000 -image_base 100000000
        endif
    endif
endif

CXX_CMD = $(CC) $(OTHER_CXXFLAGS) $(USER_CXX_FLAGS) $(WARN_FLAGS) $(INCLUDE_PATH_FLAGS)
LINK_CMD = $(LD) $(LIB_PATH_FLAGS) $(LDFLAGS)

# Throwaway variables to let us use spaces as an argument:
# https://www.gnu.org/software/make/manual/make.html#Syntax-of-Functions
_empty =
_space = $(_empty) $(_empty)

# DYLD_FALLBACK_LIBRARY_PATH is for MacOS, LD_LIBRARY_PATH is for all other *NIX
# systems.
LIBRARY_COLON_PATHS = $(subst $(_space),:,$(LIBRARY_DIRECTORIES))
SET_SEARCH_PATHS = eval "$$($(LUAROCKS) path)" ; \
		export LD_LIBRARY_PATH="$(LIBRARY_COLON_PATHS):$$LD_LIBRARY_PATH" ; \
		export DYLD_FALLBACK_LIBRARY_PATH="$(LIBRARY_COLON_PATHS):$$DYLD_FALLBACK_LIBRARY_PATH"

DOCTEST_TAG = v2.4.11
DOCTEST_HEADER = tests/c/doctest.h

# Uncomment for debugging autogenerated files
# .PRECIOUS: $(AUTOGENERATED_CPP_FILES) $(AUTOGENERATED_HPP_FILES) $(CONSTANT_FILES)

.PHONY: all
all: $(LIB_BUILD_TARGET)


.PHONY: install
install: $(LIB_BUILD_TARGET)
	install $^ $(INST_LIBDIR)


.PHONY: clean
clean:
	$(RM) $(LIB_OBJECT_FILES) $(CONSTANT_FILES) $(LIB_BUILD_TARGET)
	$(RM) $(TEST_EXECUTABLE) $(TEST_CPP_OBJECT_FILES) $(DOCTEST_HEADER)
	$(RM) -r $(BUILD_DIR) $(CONSTS_DIR) $(AUTOGENERATED_CPP_FILES) $(AUTOGENERATED_HPP_FILES)


.PHONY: test
test: $(TEST_EXECUTABLE) $(TEST_LUA_SOURCES)
	$(SET_SEARCH_PATHS); $(TEST_EXECUTABLE)
	$(SET_SEARCH_PATHS); \
		$(BUSTED) $(BUSTED_FLAGS)                           \
		          --cpath="$(BUILD_DIR)/?.$(LIB_EXTENSION)" \
		          --lua=$(LUA)                              \
		          --shuffle                                 \
		          -p lua                                    \
		          tests/lua


.PHONY: format
format:
	@clang-format --Werror -i --verbose \
	    $(filter-out $(AUTOGENERATED_CPP_FILES),$(wildcard src/*.cpp)) \
	    $(filter-out $(AUTOGENERATED_HPP_FILES),$(wildcard include/unicornlua/*.hpp)) \
	    $(wildcard tests/c/*.cpp) \
	    $(wildcard tests/c/*.hpp)


# Convenience target for generating all templated files. This is mostly for
# making IDEs and linters shut up about "missing" files.
.PHONY: autogen-files
autogen-files: $(AUTOGENERATED_CPP_FILES) $(AUTOGENERATED_HPP_FILES) $(CONSTANT_FILES)

$(DOCTEST_HEADER):
	$(CURL) -sSo $@ https://raw.githubusercontent.com/doctest/doctest/$(DOCTEST_TAG)/doctest/doctest.h


$(LIB_BUILD_TARGET): $(LIB_OBJECT_FILES) | $(BUILD_DIR)
	$(LINK_CMD) $(LIBFLAG) -o $@ $^ $(REQUIRED_LIBS_FLAGS)


$(TEST_EXECUTABLE): $(DOCTEST_HEADER) $(TEST_CPP_OBJECT_FILES) $(LIB_OBJECT_FILES) $(TEST_HEADERS)
	$(LINK_CMD) -o $@ $(filter %.$(OBJ_EXTENSION),$^) $(REQUIRED_LIBS_FLAGS) $(LINK_TO_LUA_FLAG) -lm


$(CONSTS_DIR)/%_const.cpp: $(UNICORN_INCDIR)/unicorn/%.h | $(CONSTS_DIR)
	@echo "Generating $@"
	$(SET_SEARCH_PATHS); $(LUA) tools/generate_constants.lua $< $@


%.$(OBJ_EXTENSION): %.cpp $(AUTOGENERATED_HPP_FILES)
	$(CXX_CMD) $(CXXFLAGS) -c -o $@ $<


%.cpp: %.template $(TEMPLATE_DATA_FILES)
	@echo "Generating $@"
	$(SET_SEARCH_PATHS); $(LUA) tools/render_template.lua -o $@ $^


%.hpp: %.template $(TEMPLATE_DATA_FILES)
	@echo "Generating $@"
	$(SET_SEARCH_PATHS); $(LUA) tools/render_template.lua -o $@ $^


$(CONSTS_DIR) $(BUILD_DIR):
	$(MKDIR) $@
