/**
 * Exceptions for the Lua bindings for the Unicorn CPU emulator.
 */

#ifndef INCLUDE_UNICORNLUA_ERRORS_H_
#define INCLUDE_UNICORNLUA_ERRORS_H_

#include <stdexcept>

#include <unicorn/unicorn.h>

#include "unicornlua/lua.h"

/**
 * Exception class for translating Unicorn error codes into C++ exceptions.
 */
class UnicornLibraryError : public std::runtime_error {
public:
    explicit UnicornLibraryError(uc_err error);

    /** Return the Unicorn error code that triggered this exception. */
    uc_err get_error() const noexcept;
    void rethrow_as_lua_error(lua_State *L);

private:
    uc_err error_;
};


/**
 * Base class for exceptions thrown due to an error in the Lua binding.
 *
 * Unlike @ref UnicornLibraryError, these exceptions are never thrown when a library
 * operation fails. Rather, this exception is used when something goes wrong with the
 * glue code, such as when Lua passes the wrong kind of argument to a function.
 */
class UnicornLuaError : public std::runtime_error {
public:
    void rethrow_as_lua_error(lua_State *L);
};

#endif  // INCLUDE_UNICORNLUA_ERRORS_H_