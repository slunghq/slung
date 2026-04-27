use proc_macro::TokenStream;
use quote::quote;
use syn::{Ident, ItemFn};

/// #[source] macro to emit descriptor export for a Slung source.
///
/// Generates a source descriptor JSON and exports `__slung_source_<Name>_descriptor`.
/// Also generates placeholder mapper functions `__slung_map_<Source>_<field>` for each field.
///
/// The descriptor tells the host:
/// + Source name and connector kind
/// + List of components (fields) attached to this entity
/// + Mapper export names the host should call for each component
/// + Whether components are dynamic (produce EntityKeys)
///
/// Per CAPABILITY_GRAPH.md, each source field becomes a component with a mapper export.
#[proc_macro_attribute]
pub fn source(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let input = syn::parse_macro_input!(item as syn::ItemStruct);
    let source_name = input.ident.clone();

    // Build components array from struct fields
    let mut components_json: Vec<String> = Vec::new();
    let mut mapper_idents: Vec<Ident> = Vec::new();

    for field in input.fields.iter() {
        if let Some(field_ident) = &field.ident {
            // Get type name from path or use "Unknown"
            let field_type = match &field.ty {
                syn::Type::Path(p) => p
                    .path
                    .segments
                    .last()
                    .map(|s| s.ident.to_string())
                    .unwrap_or_else(|| "Unknown".to_string()),
                _ => "Unknown".to_string(),
            };

            let mapper_export = format!("__slung_map_{}_{}", source_name, field_ident);

            components_json.push(format!(
                r#"{{"name":"{}","type_name":"{}","mapper":"{}","dynamic":false}}"#,
                field_ident, field_type, mapper_export
            ));

            mapper_idents.push(syn::Ident::new(&mapper_export, field_ident.span()));
        }
    }

    let components_json_str = components_json.join(",");
    let descriptor_json = format!(
        r#"{{"name":"{}","kind":"builtin","builtin":"custom","config":"{{}}","components":[{}]}}"#,
        source_name, components_json_str
    );

    let descriptor_lit = syn::LitStr::new(&descriptor_json, input.ident.span());
    let descriptor_fn = syn::Ident::new(
        &format!("__slung_source_{}_descriptor", source_name),
        input.ident.span(),
    );

    // Create unique static descriptor name based on source name
    let descriptor_static = syn::Ident::new(
        &format!("__SOURCE_DESC_{}", source_name),
        input.ident.span(),
    );

    quote! {
        #[allow(unsafe_code, unsafe_attr_outside_unsafe)]
        const _: () = {
            #input

            #[allow(unsafe_code)]
            #[allow(non_upper_case_globals)]
            static #descriptor_static: &'static str = #descriptor_lit;

            #[allow(unsafe_code)]
            #[allow(non_snake_case)]
            #[unsafe(no_mangle)]
            pub extern "C" fn #descriptor_fn() -> u64 {
                let len = #descriptor_static.len() as u64;
                let ptr = #descriptor_static.as_ptr() as usize as u64;
                (ptr << 32) | len
            }

            #(
                #[allow(unsafe_code)]
                #[allow(non_snake_case)]
                #[unsafe(no_mangle)]
                pub extern "C" fn #mapper_idents(
                    _raw_ptr: *const u8,
                    _raw_len: u32,
                    _out_ptr: *mut u8,
                    _out_len: *mut u32,
                ) -> i32 {
                    // Placeholder: implement mapping logic to convert raw bytes to component type
                    1
                }
            )*
        };
    }
    .into()
}

/// #[component] macro to emit descriptor export for a Slung component type.
///
/// Generates a component descriptor JSON and exports `__slung_component_<Name>_descriptor`.
/// The descriptor tells the host what fields this component type contains.
///
/// The host uses this descriptor to attach serialize/deserialize boundaries so it can
/// read and write component values across the Wasm linear memory boundary.
///
/// Per CAPABILITY_GRAPH.md Step 2, component descriptors enrich component entries
/// registered in Step 1 with type information.
#[proc_macro_attribute]
pub fn component(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let input = syn::parse_macro_input!(item as syn::ItemStruct);
    let component_name = input.ident.clone();

    // Extract field names from the struct
    let mut field_names: Vec<String> = Vec::new();
    for field in input.fields.iter() {
        if let Some(field_ident) = &field.ident {
            field_names.push(field_ident.to_string());
        }
    }

    let fields_json = field_names
        .iter()
        .map(|f| format!(r#""{}""#, f))
        .collect::<Vec<_>>()
        .join(",");

    let descriptor_json = format!(
        r#"{{"name":"{}","fields":[{}]}}"#,
        component_name, fields_json
    );

    let descriptor_lit = syn::LitStr::new(&descriptor_json, input.ident.span());
    let descriptor_fn = syn::Ident::new(
        &format!("__slung_component_{}_descriptor", component_name),
        input.ident.span(),
    );

    // Create unique static descriptor name based on component name
    let descriptor_static = syn::Ident::new(
        &format!("__COMPONENT_DESC_{}", component_name),
        input.ident.span(),
    );

    quote! {
        #[allow(unsafe_code, unsafe_attr_outside_unsafe)]
        const _: () = {
            #input

            #[allow(unsafe_code)]
            #[allow(non_upper_case_globals)]
            static #descriptor_static: &'static str = #descriptor_lit;

            #[allow(unsafe_code)]
            #[allow(non_snake_case)]
            #[unsafe(no_mangle)]
            pub extern "C" fn #descriptor_fn() -> u64 {
                let len = #descriptor_static.len() as u64;
                let ptr = #descriptor_static.as_ptr() as usize as u64;
                (ptr << 32) | len
            }
        };
    }
    .into()
}

/// #[rule] macro to emit descriptor export and entrypoint for a Slung rule.
///
/// Generates a rule descriptor JSON and exports both:
/// + `__slung_rule_<Name>_descriptor` - the descriptor getter
/// + `__slung_rule_<Name>` - the rule entrypoint the host calls
///
/// The descriptor tells the host:
/// + Rule name and execution priority
/// + Watch list: which (Source::component) pairs trigger this rule
///
/// The host uses the descriptor to wire this rule into the capability graph during module load.
/// When any watched component becomes dirty, the host calls the rule entrypoint export.
///
/// Per CAPABILITY_GRAPH.md Step 3, the host scans for rule descriptors and wires
/// them into the graph before the module goes live.
#[proc_macro_attribute]
pub fn rule(attr: TokenStream, item: TokenStream) -> TokenStream {
    let input = syn::parse_macro_input!(item as ItemFn);
    let rule_fn_name = input.sig.ident.clone();

    // Parse rule attributes: watch list and priority
    let attr_str = attr.to_string();
    let (watch_list, priority) = parse_rule_attributes(&attr_str);

    // Build watch array JSON
    let watch_json = watch_list
        .iter()
        .map(|w| format!(r#""{}""#, w))
        .collect::<Vec<_>>()
        .join(",");

    let descriptor_json = format!(
        r#"{{"name":"{}","watch":[{}],"priority":{}}}"#,
        rule_fn_name, watch_json, priority
    );

    let descriptor_lit = syn::LitStr::new(&descriptor_json, rule_fn_name.span());
    let descriptor_fn = syn::Ident::new(
        &format!("__slung_rule_{}_descriptor", rule_fn_name),
        rule_fn_name.span(),
    );

    let entrypoint_fn = syn::Ident::new(
        &format!("__slung_rule_{}", rule_fn_name),
        rule_fn_name.span(),
    );

    // Create unique static descriptor name based on rule name
    let descriptor_static = syn::Ident::new(
        &format!("__RULE_DESC_{}", rule_fn_name),
        rule_fn_name.span(),
    );

    quote! {
        #[allow(unsafe_code, unsafe_attr_outside_unsafe)]
        const _: () = {
            #input

            #[allow(unsafe_code)]
            #[allow(non_upper_case_globals)]
            static #descriptor_static: &'static str = #descriptor_lit;

            #[allow(unsafe_code)]
            #[allow(non_snake_case)]
            #[unsafe(no_mangle)]
            pub extern "C" fn #descriptor_fn() -> u64 {
                let len = #descriptor_static.len() as u64;
                let ptr = #descriptor_static.as_ptr() as usize as u64;
                (ptr << 32) | len
            }

            #[allow(unsafe_code)]
            #[allow(non_snake_case)]
            #[unsafe(no_mangle)]
            pub extern "C" fn #entrypoint_fn() -> i32 {
                #rule_fn_name();
                0
            }
        };
    }
    .into()
}

/// Parse rule macro attributes to extract watch list and priority.
/// Handles format like: watch = ["Source1::field1", "Source2::field2"], priority = 10
fn parse_rule_attributes(attr_str: &str) -> (Vec<String>, u8) {
    let mut watch_list = Vec::new();
    let mut priority = 0u8;

    // Parse watch list
    if let Some(watch_pos) = attr_str.find("watch")
        && let Some(bracket_start) = attr_str[watch_pos..].find('[')
    {
        let start_idx = watch_pos + bracket_start + 1;
        if let Some(bracket_end) = attr_str[start_idx..].find(']') {
            let watch_content = &attr_str[start_idx..start_idx + bracket_end];
            for part in watch_content.split(',') {
                let cleaned = part.trim().trim_matches('"').trim_matches('\'').to_string();
                if !cleaned.is_empty() {
                    watch_list.push(cleaned);
                }
            }
        }
    }

    // Parse priority
    if let Some(priority_pos) = attr_str.find("priority")
        && let Some(eq_pos) = attr_str[priority_pos..].find('=')
    {
        let value_start = priority_pos + eq_pos + 1;
        let remainder = attr_str[value_start..].trim();
        let mut num_str = String::new();
        for ch in remainder.chars() {
            if ch.is_ascii_digit() {
                num_str.push(ch);
            } else {
                break;
            }
        }
        if let Ok(n) = num_str.parse::<u8>() {
            priority = n;
        }
    }

    (watch_list, priority)
}
