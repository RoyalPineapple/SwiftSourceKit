#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint64_t data[3];
} sourcekitd_variant_t;

typedef void *sourcekitd_object_t;
typedef void *sourcekitd_response_t;
typedef void *sourcekitd_uid_t;
typedef int32_t sourcekitd_variant_type_t;
typedef bool (*sourcekitd_variant_dictionary_applier_f_t)(sourcekitd_uid_t key, sourcekitd_variant_t value, void *context);

enum {
    SK_NULL = 0,
    SK_DICTIONARY = 1,
    SK_ARRAY = 2,
    SK_INT64 = 3,
    SK_STRING = 4,
    SK_UID = 5,
    SK_BOOL = 6,
    SK_DOUBLE = 7,
    SK_DATA = 8,
    SK_UNSUPPORTED = 99
};

typedef struct FakeValue FakeValue;

typedef struct {
    char *key;
    FakeValue *value;
} FakeEntry;

struct FakeValue {
    int type;
    int refcount;
    char *string;
    int64_t int64;
    bool bool_value;
    double double_value;
    uint8_t *data;
    size_t data_size;
    FakeEntry *entries;
    size_t entry_count;
    size_t entry_capacity;
    FakeValue **items;
    size_t item_count;
    size_t item_capacity;
};

typedef struct {
    FakeValue *value;
    bool is_error;
    int64_t error_kind;
    const char *error_description;
} FakeResponse;

static int64_t live_values = 0;

static sourcekitd_variant_t variant(FakeValue *value) {
    sourcekitd_variant_t result = {{0, 0, 0}};
    result.data[0] = (uint64_t)(uintptr_t)value;
    return result;
}

static FakeValue *value_from_variant(sourcekitd_variant_t value) {
    return (FakeValue *)(uintptr_t)value.data[0];
}

static FakeValue *new_value(int type) {
    FakeValue *value = calloc(1, sizeof(FakeValue));
    value->type = type;
    value->refcount = 1;
    live_values += 1;
    return value;
}

static void retain(FakeValue *value) {
    if (value) {
        value->refcount += 1;
    }
}

static void release(FakeValue *value) {
    if (!value) {
        return;
    }
    value->refcount -= 1;
    if (value->refcount > 0) {
        return;
    }
    for (size_t index = 0; index < value->entry_count; index += 1) {
        free(value->entries[index].key);
        release(value->entries[index].value);
    }
    for (size_t index = 0; index < value->item_count; index += 1) {
        release(value->items[index]);
    }
    free(value->entries);
    free(value->items);
    free(value->string);
    free(value->data);
    free(value);
    live_values -= 1;
}

static FakeValue *make_string(const char *string) {
    FakeValue *value = new_value(SK_STRING);
    value->string = string ? strdup(string) : NULL;
    return value;
}

static FakeValue *make_int64(int64_t int64) {
    FakeValue *value = new_value(SK_INT64);
    value->int64 = int64;
    return value;
}

static FakeValue *make_uid(const char *uid) {
    FakeValue *value = new_value(SK_UID);
    value->string = uid ? strdup(uid) : NULL;
    return value;
}

static FakeValue *make_bool(bool bool_value) {
    FakeValue *value = new_value(SK_BOOL);
    value->bool_value = bool_value;
    return value;
}

static FakeValue *make_double(double double_value) {
    FakeValue *value = new_value(SK_DOUBLE);
    value->double_value = double_value;
    return value;
}

static FakeValue *make_data(const uint8_t *bytes, size_t size) {
    FakeValue *value = new_value(SK_DATA);
    if (bytes && size > 0) {
        value->data = malloc(size);
        memcpy(value->data, bytes, size);
        value->data_size = size;
    }
    return value;
}

static FakeValue *make_null(void) {
    return new_value(SK_NULL);
}

static FakeValue *make_dictionary(void) {
    return new_value(SK_DICTIONARY);
}

static FakeValue *make_array(void) {
    return new_value(SK_ARRAY);
}

static void dictionary_set(FakeValue *dictionary, const char *key, FakeValue *child) {
    if (dictionary->entry_count == dictionary->entry_capacity) {
        dictionary->entry_capacity = dictionary->entry_capacity == 0 ? 4 : dictionary->entry_capacity * 2;
        dictionary->entries = realloc(dictionary->entries, dictionary->entry_capacity * sizeof(FakeEntry));
    }
    dictionary->entries[dictionary->entry_count].key = strdup(key);
    dictionary->entries[dictionary->entry_count].value = child;
    retain(child);
    dictionary->entry_count += 1;
}

static FakeValue *dictionary_get(FakeValue *dictionary, const char *key) {
    if (!dictionary || dictionary->type != SK_DICTIONARY) {
        return NULL;
    }
    for (size_t index = 0; index < dictionary->entry_count; index += 1) {
        if (strcmp(dictionary->entries[index].key, key) == 0) {
            return dictionary->entries[index].value;
        }
    }
    return NULL;
}

static void array_append(FakeValue *array, FakeValue *child) {
    if (array->item_count == array->item_capacity) {
        array->item_capacity = array->item_capacity == 0 ? 4 : array->item_capacity * 2;
        array->items = realloc(array->items, array->item_capacity * sizeof(FakeValue *));
    }
    array->items[array->item_count] = child;
    retain(child);
    array->item_count += 1;
}

static const char *string_value(FakeValue *value) {
    return value ? value->string : NULL;
}

static FakeResponse *make_response(FakeValue *value) {
    FakeResponse *response = calloc(1, sizeof(FakeResponse));
    response->value = value;
    retain(value);
    release(value);
    return response;
}

static FakeResponse *make_error_response(int64_t kind, const char *description) {
    FakeResponse *response = calloc(1, sizeof(FakeResponse));
    response->is_error = true;
    response->error_kind = kind;
    response->error_description = description;
    return response;
}

static FakeValue *compiler_version_response(void) {
    FakeValue *dictionary = make_dictionary();
    FakeValue *major = make_int64(6);
    FakeValue *minor = make_int64(1);
    FakeValue *patch = make_int64(0);
    dictionary_set(dictionary, "key.version_major", major);
    dictionary_set(dictionary, "key.version_minor", minor);
    dictionary_set(dictionary, "key.version_patch", patch);
    release(major);
    release(minor);
    release(patch);
    return dictionary;
}

static FakeValue *full_surface_response(void) {
    uint8_t bytes[] = {1, 2, 3};
    FakeValue *dictionary = make_dictionary();
    FakeValue *array = make_array();
    FakeValue *nested = make_dictionary();
    FakeValue *null_value = make_null();
    FakeValue *int_value = make_int64(42);
    FakeValue *string = make_string("hello");
    FakeValue *uid = make_uid("uid.value");
    FakeValue *bool_value = make_bool(true);
    FakeValue *double_value = make_double(1.5);
    FakeValue *data = make_data(bytes, sizeof(bytes));
    FakeValue *array_item = make_string("first");
    FakeValue *nested_item = make_int64(7);

    array_append(array, array_item);
    dictionary_set(nested, "nested.int", nested_item);
    dictionary_set(dictionary, "null", null_value);
    dictionary_set(dictionary, "int64", int_value);
    dictionary_set(dictionary, "string", string);
    dictionary_set(dictionary, "uid", uid);
    dictionary_set(dictionary, "bool", bool_value);
    dictionary_set(dictionary, "double", double_value);
    dictionary_set(dictionary, "data", data);
    dictionary_set(dictionary, "array", array);
    dictionary_set(dictionary, "dictionary", nested);

    release(array);
    release(nested);
    release(null_value);
    release(int_value);
    release(string);
    release(uid);
    release(bool_value);
    release(double_value);
    release(data);
    release(array_item);
    release(nested_item);
    return dictionary;
}

static bool request_matches_encoding_fixture(FakeValue *request) {
    FakeValue *array = dictionary_get(request, "array");
    FakeValue *nested = dictionary_get(request, "nested");
    FakeValue *name = dictionary_get(request, "name");
    FakeValue *uid = dictionary_get(request, "uid");
    if (!array || array->type != SK_ARRAY || array->item_count != 3) {
        return false;
    }
    return name && strcmp(string_value(name), "root") == 0
        && uid && strcmp(string_value(uid), "uid.request") == 0
        && strcmp(string_value(array->items[0]), "first") == 0
        && array->items[1]->int64 == 2
        && array->items[2]->type == SK_DICTIONARY
        && nested && dictionary_get(nested, "child");
}

void sourcekitd_initialize(void) {}
void sourcekitd_shutdown(void) {}

sourcekitd_uid_t sourcekitd_uid_get_from_cstr(const char *string) {
    return (sourcekitd_uid_t)strdup(string);
}

const char *sourcekitd_uid_get_string_ptr(sourcekitd_uid_t uid) {
    return (const char *)uid;
}

sourcekitd_object_t sourcekitd_request_dictionary_create(const sourcekitd_uid_t *keys, const sourcekitd_object_t *values, size_t count) {
    FakeValue *dictionary = make_dictionary();
    for (size_t index = 0; index < count; index += 1) {
        dictionary_set(dictionary, (const char *)keys[index], (FakeValue *)values[index]);
    }
    return dictionary;
}

void sourcekitd_request_dictionary_set_string(sourcekitd_object_t object, sourcekitd_uid_t key, const char *string) {
    FakeValue *value = make_string(string);
    dictionary_set(object, key, value);
    release(value);
}

void sourcekitd_request_dictionary_set_int64(sourcekitd_object_t object, sourcekitd_uid_t key, int64_t int64) {
    FakeValue *value = make_int64(int64);
    dictionary_set(object, key, value);
    release(value);
}

void sourcekitd_request_dictionary_set_uid(sourcekitd_object_t object, sourcekitd_uid_t key, sourcekitd_uid_t uid) {
    FakeValue *value = make_uid(uid);
    dictionary_set(object, key, value);
    release(value);
}

void sourcekitd_request_dictionary_set_value(sourcekitd_object_t object, sourcekitd_uid_t key, sourcekitd_object_t value) {
    dictionary_set(object, key, value);
}

sourcekitd_object_t sourcekitd_request_array_create(const sourcekitd_object_t *values, size_t count) {
    FakeValue *array = make_array();
    for (size_t index = 0; index < count; index += 1) {
        array_append(array, (FakeValue *)values[index]);
    }
    return array;
}

void sourcekitd_request_array_set_string(sourcekitd_object_t object, size_t index, const char *string) {
    FakeValue *value = make_string(string);
    array_append(object, value);
    release(value);
}

void sourcekitd_request_array_set_int64(sourcekitd_object_t object, size_t index, int64_t int64) {
    FakeValue *value = make_int64(int64);
    array_append(object, value);
    release(value);
}

void sourcekitd_request_array_set_uid(sourcekitd_object_t object, size_t index, sourcekitd_uid_t uid) {
    FakeValue *value = make_uid(uid);
    array_append(object, value);
    release(value);
}

void sourcekitd_request_array_set_value(sourcekitd_object_t object, size_t index, sourcekitd_object_t value) {
    array_append(object, value);
}

sourcekitd_object_t sourcekitd_request_string_create(const char *string) {
    return make_string(string);
}

sourcekitd_object_t sourcekitd_request_int64_create(int64_t int64) {
    return make_int64(int64);
}

sourcekitd_object_t sourcekitd_request_uid_create(sourcekitd_uid_t uid) {
    return make_uid(uid);
}

void sourcekitd_request_release(sourcekitd_object_t object) {
    release(object);
}

#ifndef FAKE_SOURCEKITD_OMIT_SEND_REQUEST_SYNC
sourcekitd_response_t sourcekitd_send_request_sync(sourcekitd_object_t request_object) {
    FakeValue *request = request_object;
    FakeValue *request_uid = dictionary_get(request, "key.request");
    const char *request_name = string_value(request_uid);

    if (!request_name) {
        return make_error_response(1, "missing key.request");
    }
    if (strcmp(request_name, "source.request.compiler_version") == 0) {
        return make_response(compiler_version_response());
    }
    if (strcmp(request_name, "swift-sourcekit-test.full_surface") == 0) {
        return make_response(full_surface_response());
    }
    if (strcmp(request_name, "swift-sourcekit-test.error") == 0) {
        return make_error_response(22, "synthetic sourcekitd error");
    }
    if (strcmp(request_name, "swift-sourcekit-test.null_response") == 0) {
        return NULL;
    }
    if (strcmp(request_name, "swift-sourcekit-test.unsupported_variant") == 0) {
        return make_response(new_value(SK_UNSUPPORTED));
    }
    if (strcmp(request_name, "swift-sourcekit-test.null_string_data") == 0) {
        FakeValue *dictionary = make_dictionary();
        FakeValue *string = make_string(NULL);
        FakeValue *data = make_data(NULL, 3);
        dictionary_set(dictionary, "string", string);
        dictionary_set(dictionary, "data", data);
        release(string);
        release(data);
        return make_response(dictionary);
    }
    if (strcmp(request_name, "swift-sourcekit-test.encoding") == 0) {
        return make_response(make_string(request_matches_encoding_fixture(request) ? "ok" : "bad"));
    }
    if (strcmp(request_name, "swift-sourcekit-test.live_values") == 0) {
        return make_response(make_int64(live_values));
    }

    return make_error_response(2, "unknown request");
}
#endif

void sourcekitd_response_dispose(sourcekitd_response_t response_object) {
    FakeResponse *response = response_object;
    release(response->value);
    free(response);
}

int sourcekitd_response_is_error(sourcekitd_response_t response) {
    return ((FakeResponse *)response)->is_error;
}

int64_t sourcekitd_response_error_get_kind(sourcekitd_response_t response) {
    return ((FakeResponse *)response)->error_kind;
}

const char *sourcekitd_response_error_get_description(sourcekitd_response_t response) {
    return ((FakeResponse *)response)->error_description;
}

sourcekitd_variant_t sourcekitd_response_get_value(sourcekitd_response_t response) {
    return variant(((FakeResponse *)response)->value);
}

sourcekitd_variant_type_t sourcekitd_variant_get_type(sourcekitd_variant_t value) {
    FakeValue *fake = value_from_variant(value);
    return fake ? fake->type : SK_NULL;
}

int64_t sourcekitd_variant_int64_get_value(sourcekitd_variant_t value) {
    return value_from_variant(value)->int64;
}

bool sourcekitd_variant_bool_get_value(sourcekitd_variant_t value) {
    return value_from_variant(value)->bool_value;
}

double sourcekitd_variant_double_get_value(sourcekitd_variant_t value) {
    return value_from_variant(value)->double_value;
}

const char *sourcekitd_variant_string_get_ptr(sourcekitd_variant_t value) {
    return value_from_variant(value)->string;
}

size_t sourcekitd_variant_data_get_size(sourcekitd_variant_t value) {
    return value_from_variant(value)->data_size;
}

const void *sourcekitd_variant_data_get_ptr(sourcekitd_variant_t value) {
    return value_from_variant(value)->data;
}

sourcekitd_uid_t sourcekitd_variant_uid_get_value(sourcekitd_variant_t value) {
    return value_from_variant(value)->string;
}

sourcekitd_variant_t sourcekitd_variant_dictionary_get_value(sourcekitd_variant_t dictionary, sourcekitd_uid_t key) {
    return variant(dictionary_get(value_from_variant(dictionary), key));
}

const char *sourcekitd_variant_dictionary_get_string(sourcekitd_variant_t dictionary, sourcekitd_uid_t key) {
    return string_value(dictionary_get(value_from_variant(dictionary), key));
}

int64_t sourcekitd_variant_dictionary_get_int64(sourcekitd_variant_t dictionary, sourcekitd_uid_t key) {
    FakeValue *value = dictionary_get(value_from_variant(dictionary), key);
    return value ? value->int64 : 0;
}

sourcekitd_uid_t sourcekitd_variant_dictionary_get_uid(sourcekitd_variant_t dictionary, sourcekitd_uid_t key) {
    FakeValue *value = dictionary_get(value_from_variant(dictionary), key);
    return value ? value->string : NULL;
}

bool sourcekitd_variant_dictionary_apply_f(sourcekitd_variant_t dictionary, sourcekitd_variant_dictionary_applier_f_t applier, void *context) {
    FakeValue *value = value_from_variant(dictionary);
    for (size_t index = 0; index < value->entry_count; index += 1) {
        if (!applier(value->entries[index].key, variant(value->entries[index].value), context)) {
            return false;
        }
    }
    return true;
}

size_t sourcekitd_variant_array_get_count(sourcekitd_variant_t array) {
    return value_from_variant(array)->item_count;
}

sourcekitd_variant_t sourcekitd_variant_array_get_value(sourcekitd_variant_t array, size_t index) {
    FakeValue *value = value_from_variant(array);
    if (index >= value->item_count) {
        return variant(NULL);
    }
    return variant(value->items[index]);
}
