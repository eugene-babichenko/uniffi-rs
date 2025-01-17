{% import "macros.swift" as swift %}
{%- let cbi = self.inner() %}
{%- let type_name = cbi|type_name %}
{%- let canonical_type_name = cbi|canonical_name %}
{%- let ffi_converter = format!("ffiConverter{}", canonical_type_name) %}
{%- let foreign_callback = format!("foreignCallback{}", canonical_type_name) %}

// Declaration and FfiConverters for {{ type_name }} Callback Interface

public protocol {{ type_name }} : AnyObject {
    {% for meth in cbi.methods() -%}
    func {{ meth.name()|fn_name }}({% call swift::arg_list_protocol(meth) %}) {% call swift::throws(meth) -%}
    {%- match meth.return_type() -%}
    {%- when Some with (return_type) %} -> {{ return_type|type_name -}}
    {%- else -%}
    {%- endmatch %}
    {% endfor %}
}

// The ForeignCallback that is passed to Rust.
fileprivate let {{ foreign_callback }} : ForeignCallback =
    { (handle: Handle, method: Int32, args: RustBuffer, out_buf: UnsafeMutablePointer<RustBuffer>) -> Int32 in
        {% for meth in cbi.methods() -%}
    {%- let method_name = format!("invoke_{}", meth.name())|fn_name -%}

    func {{ method_name }}(_ swiftCallbackInterface: {{ type_name }}, _ args: RustBuffer) throws -> RustBuffer {
        defer { args.deallocate() }
        {#- Unpacking args from the RustBuffer #}
            {%- if meth.arguments().len() != 0 -%}
            {#- Calling the concrete callback object #}

            let reader = Reader(data: Data(rustBuffer: args))
            {% if meth.return_type().is_some() %}let result = {% endif -%}
            {% if meth.throws().is_some() %}try {% endif -%}
            swiftCallbackInterface.{{ meth.name()|fn_name }}(
                    {% for arg in meth.arguments() -%}
                    {{ arg.name() }}: try {{ "reader"|read_var(arg) }}
                    {%- if !loop.last %}, {% endif %}
                    {% endfor -%}
                )
            {% else %}
            {% if meth.return_type().is_some() %}let result = {% endif -%}
            {% if meth.throws().is_some() %}try {% endif -%}
            swiftCallbackInterface.{{ meth.name()|fn_name }}()
            {% endif -%}

        {#- Packing up the return value into a RustBuffer #}
                {%- match meth.return_type() -%}
                {%- when Some with (return_type) -%}
                let writer = Writer()
                {{ "result"|write_var("writer", return_type) }}
                return RustBuffer(bytes: writer.bytes)
                {%- else -%}
                return RustBuffer()
                {% endmatch -%}
                // TODO catch errors and report them back to Rust.
                // https://github.com/mozilla/uniffi-rs/issues/351

    }
    {% endfor %}

        let cb = try! {{ ffi_converter }}.lift(handle)
        switch method {
            case IDX_CALLBACK_FREE:
                {{ ffi_converter }}.drop(handle: handle)
                // No return value.
                // See docs of ForeignCallback in `uniffi/src/ffi/foreigncallbacks.rs`
                return 0
            {% for meth in cbi.methods() -%}
            {% let method_name = format!("invoke_{}", meth.name())|fn_name -%}
            case {{ loop.index }}:
                let buffer = try! {{ method_name }}(cb, args)
                out_buf.pointee = buffer
                // Value written to out buffer.
                // See docs of ForeignCallback in `uniffi/src/ffi/foreigncallbacks.rs`
                return 1
            {% endfor %}
            // This should never happen, because an out of bounds method index won't
            // ever be used. Once we can catch errors, we should return an InternalError.
            // https://github.com/mozilla/uniffi-rs/issues/351
            default:
                // An unexpected error happened.
                // See docs of ForeignCallback in `uniffi/src/ffi/foreigncallbacks.rs`
                return -1
        }
    }

// The ffiConverter which transforms the Callbacks in to Handles to pass to Rust.
private let {{ ffi_converter }}: FfiConverterCallbackInterface<{{ type_name }}> = {
    try! rustCall { (err: UnsafeMutablePointer<RustCallStatus>) in
            {{ cbi.ffi_init_callback().name() }}({{ foreign_callback }}, err)
    }
    return FfiConverterCallbackInterface<{{ type_name }}>()
}()
