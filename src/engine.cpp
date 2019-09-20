extern "C" {
#include <lua.h>
}
#include <unicorn/unicorn.h>

#include "unicornlua/context.h"
#include "unicornlua/engine.h"
#include "unicornlua/errors.h"
#include "unicornlua/hooks.h"
#include "unicornlua/unicornlua.h"
#include "unicornlua/utils.h"

const char * const kEngineMetatableName = "unicornlua__engine_meta";
const char * const kEnginePointerMapName = "unicornlua__engine_ptr_map";


const luaL_Reg kEngineMetamethods[] = {
    {"__gc", ul_close},
    {nullptr, nullptr}
};


const luaL_Reg kEngineInstanceMethods[] = {
    {"close", ul_close},
    {"context_restore", ul_context_restore},
    {"context_save", ul_context_save},
    {"emu_start", ul_emu_start},
    {"emu_stop", ul_emu_stop},
    {"errno", ul_errno},
    {"hook_add", ul_hook_add},
    {"hook_del", ul_hook_del},
    {"mem_map", ul_mem_map},
    {"mem_protect", ul_mem_protect},
    {"mem_read", ul_mem_read},
    {"mem_regions", ul_mem_regions},
    {"mem_unmap", ul_mem_unmap},
    {"mem_write", ul_mem_write},
    {"query", ul_query},
    {"reg_read", ul_reg_read},
    {"reg_read_batch", ul_reg_read_batch},
    {"reg_write", ul_reg_write},
    {"reg_write_batch", ul_reg_write_batch},
    {nullptr, nullptr}
};


UCLuaEngine::UCLuaEngine(lua_State *L, uc_engine *engine) : L(L), engine(engine) {}


UCLuaEngine::~UCLuaEngine() {
    // Only close the engine if it hasn't already been closed. It's perfectly legitimate
    // for the user to close the engine before it gets garbage-collected, so we don't
    // want to crash on garbage collection if they did so.
    if (engine != nullptr)
        close();
}


Hook *UCLuaEngine::create_empty_hook() {
    Hook *hook = new Hook(this->L, this->engine);
    hooks_.insert(hook);
    return hook;
}


Hook *UCLuaEngine::create_hook(
    uc_hook hook_handle, int callback_func_ref, int user_data_ref
) {
    Hook *hook = new Hook(
        this->L, this->engine, hook_handle, callback_func_ref, user_data_ref
    );
    hooks_.insert(hook);
    return hook;
}


void UCLuaEngine::remove_hook(Hook *hook) {
    hooks_.erase(hook);
    delete hook;
}


void UCLuaEngine::close() {
    if (engine == nullptr) {
        luaL_error(L, "Attempted to close already-closed engine: %p", this);
        return;
    }

    for (auto hook : hooks_)
        delete hook;
    hooks_.clear();

    uc_err error = uc_close(engine);
    if (error != UC_ERR_OK)
        throw UnicornLibraryError(error);

    // Signal subsequent calls that this engine is already closed.
    engine = nullptr;
}


Context *UCLuaEngine::create_context_in_lua() {
    auto context = (Context *)lua_newuserdata(L, sizeof(Context));
    new (context) Context(*this);

    luaL_setmetatable(L, kContextMetatableName);
    return context;
}


void UCLuaEngine::restore_from_context(Context *context) {
    uc_err error = uc_context_restore(engine, context->get_handle());
    if (error != UC_ERR_OK)
        throw UnicornLibraryError(error);
}


void UCLuaEngine::remove_context(Context *context) {
    delete context;
}


void ul_init_engines_lib(lua_State *L) {
    /* Create a table with weak values where the engine pointer to engine object
     * mappings will be stored. */
    ul_create_weak_table(L, "v");
    lua_setfield(L, LUA_REGISTRYINDEX, kEnginePointerMapName);

    luaL_newmetatable(L, kEngineMetatableName);
    luaL_setfuncs(L, kEngineMetamethods, 0);

    lua_newtable(L);
    luaL_setfuncs(L, kEngineInstanceMethods, 0);
    lua_setfield(L, -2, "__index");

    /* Remove the metatables from the stack. */
    lua_pop(L, 2);
}


void ul_get_engine_object(lua_State *L, const uc_engine *engine) {
    lua_getfield(L, LUA_REGISTRYINDEX, kEnginePointerMapName);
    lua_pushlightuserdata(L, (void *)engine);
    lua_gettable(L, -2);

    if (lua_isnil(L, -1)) {
        /* Remove nil and engine pointer map at TOS */
        lua_pop(L, 2);
        luaL_error(L, "No engine object is registered for pointer %p.", engine);
    }

    /* Remove the engine pointer map from the stack. */
    lua_remove(L, -2);
}


int ul_close(lua_State *L) {
    /* Deliberately not using ul_toengine, see below. */
    auto engine_object = get_engine_struct(L, 1);
    engine_object->close();

    // Garbage collection should remove the engine object from the pointer map table,
    // but we might as well do it here anyway.
    lua_getfield(L, LUA_REGISTRYINDEX, kEnginePointerMapName);
    lua_pushlightuserdata(L, (void *)engine_object->engine);
    lua_pushnil(L);
    lua_settable(L, -3);
    lua_pop(L, 1);

    return 0;
}


int ul_query(lua_State *L) {
    size_t result;
    uc_engine *engine = ul_toengine(L, 1);
    auto query_type = static_cast<uc_query_type>(luaL_checkinteger(L, 1));

    uc_err error = uc_query(engine, query_type, &result);
    if (error != UC_ERR_OK)
        return ul_crash_on_error(L, error);

    lua_pushinteger(L, result);
    return 1;
}


int ul_errno(lua_State *L) {
    uc_engine *engine = ul_toengine(L, 1);
    lua_pushinteger(L, uc_errno(engine));
    return 1;
}


int ul_emu_start(lua_State *L) {
    uc_engine *engine = ul_toengine(L, 1);
    auto start = static_cast<uint64_t>(luaL_checkinteger(L, 2));
    auto end = static_cast<uint64_t>(luaL_checkinteger(L, 3));
    auto timeout = static_cast<uint64_t>(luaL_optinteger(L, 4, 0));
    auto n_instructions = static_cast<size_t>(luaL_optinteger(L, 5, 0));

    uc_err error = uc_emu_start(engine, start, end, timeout, n_instructions);
    if (error != UC_ERR_OK)
        return ul_crash_on_error(L, error);
    return 0;
}


int ul_emu_stop(lua_State *L) {
    uc_engine *engine = ul_toengine(L, 1);
    uc_err error = uc_emu_stop(engine);

    if (error != UC_ERR_OK)
        return ul_crash_on_error(L, error);
    return 0;
}


uc_engine *ul_toengine(lua_State *L, int index) {
    auto engine_object = get_engine_struct(L, index);
    if (engine_object->engine == nullptr)
        luaL_error(L, "Attempted to use closed engine.");

    return engine_object->engine;
}
