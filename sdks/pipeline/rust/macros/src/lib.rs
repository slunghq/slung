use proc_macro::TokenStream;
use quote::quote;
use syn::parse::{Parse, ParseStream};
use syn::punctuated::Punctuated;
use syn::{
    Attribute, Expr, ExprArray, ExprLit, ExprPath, Fields, Ident, Item, ItemEnum, ItemFn,
    ItemStruct, Lit, Meta, Result, Token, Type,
};

struct SourceArgs {
    builtin: Option<String>,
}

impl Parse for SourceArgs {
    fn parse(input: ParseStream<'_>) -> Result<Self> {
        let mut builtin = None;

        while !input.is_empty() {
            let ident: Ident = input.parse()?;
            input.parse::<Token![=]>()?;
            let value: syn::LitStr = input.parse()?;

            if ident == "builtin" {
                builtin = Some(value.value());
            }

            if input.is_empty() {
                break;
            }

            input.parse::<Token![,]>()?;
        }

        Ok(Self { builtin })
    }
}

#[derive(Default)]
struct SourceFieldMeta {
    is_config: bool,
    mapper: Option<Ident>,
}

struct RuleArgs {
    watch: Vec<String>,
    priority: u8,
}

impl Parse for RuleArgs {
    fn parse(input: ParseStream<'_>) -> Result<Self> {
        let mut watch = Vec::new();
        let mut priority = 0u8;

        while !input.is_empty() {
            let ident: Ident = input.parse()?;
            input.parse::<Token![=]>()?;

            if ident == "watch" {
                let values: ExprArray = input.parse()?;
                for expr in values.elems {
                    watch.push(expr_to_watch_string(&expr)?);
                }
            } else if ident == "priority" {
                let lit: syn::LitInt = input.parse()?;
                priority = lit.base10_parse()?;
            } else {
                return Err(syn::Error::new(ident.span(), "unsupported rule attribute"));
            }

            if input.is_empty() {
                break;
            }

            input.parse::<Token![,]>()?;
        }

        Ok(Self { watch, priority })
    }
}

#[proc_macro_attribute]
pub fn source(attr: TokenStream, item: TokenStream) -> TokenStream {
    let args = syn::parse_macro_input!(attr as SourceArgs);
    let mut input = syn::parse_macro_input!(item as ItemStruct);
    let source_name = input.ident.clone();
    let builtin = args.builtin.unwrap_or_else(|| "custom".to_string());

    let mut component_descriptors = Vec::new();
    let mut component_consts = Vec::new();
    let mut mapper_exports = Vec::new();
    let mut next_component_id: u32 = 0;

    for field in input.fields.iter_mut() {
        let Some(field_ident) = &field.ident else {
            continue;
        };

        let meta = strip_source_field_attrs(&mut field.attrs);
        if meta.is_config {
            continue;
        }

        let field_name = field_ident.to_string();
        let type_name = type_name(&field.ty);
        let mapper_export = format!("__slung_map_{}_{}", source_name, field_ident);
        let mapper_ident = Ident::new(&mapper_export, field_ident.span());

        component_descriptors.push(format!(
            r#"{{"name":"{}","type_name":"{}","mapper":"{}","dynamic":false}}"#,
            field_name, type_name, mapper_export
        ));

        let field_ty = field.ty.clone();
        let component_id = next_component_id;
        next_component_id += 1;

        component_consts.push(quote! {
            #[allow(non_upper_case_globals)]
            pub const #field_ident: ::slung::ComponentKey<#field_ty> =
                ::slung::ComponentKey::new(stringify!(#source_name), stringify!(#field_ident), #component_id);
        });

        let mapper_body = if let Some(mapper) = meta.mapper {
            quote! {
                let raw = unsafe {
                    ::std::slice::from_raw_parts(_raw_ptr, _raw_len as usize)
                };
                let mapped = match #mapper(raw) {
                    Ok(value) => value,
                    Err(_) => return 1,
                };
                let encoded = match ::serde_json::to_vec(&mapped) {
                    Ok(bytes) => bytes,
                    Err(_) => return 2,
                };
                let out_len_value = encoded.len() as u32;
                unsafe {
                    ::std::ptr::copy_nonoverlapping(encoded.as_ptr(), _out_ptr, encoded.len());
                    *_out_len = out_len_value;
                }
                0
            }
        } else {
            quote! { 1 }
        };

        mapper_exports.push(quote! {
            #[allow(unsafe_code)]
            #[allow(non_snake_case)]
            #[unsafe(no_mangle)]
            pub extern "C" fn #mapper_ident(
                _raw_ptr: *const u8,
                _raw_len: u32,
                _out_ptr: *mut u8,
                _out_len: *mut u32,
            ) -> i32 {
                #mapper_body
            }
        });
    }

    let components_json = component_descriptors.join(",");
    let descriptor_json = format!(
        r#"{{"name":"{}","kind":"builtin","builtin":"{}","config":"{{}}","components":[{}]}}"#,
        source_name, builtin, components_json
    );
    let descriptor_lit = syn::LitStr::new(&descriptor_json, source_name.span());
    let descriptor_fn = Ident::new(
        &format!("__slung_source_{}_descriptor", source_name),
        source_name.span(),
    );
    let descriptor_static = Ident::new(
        &format!("__SOURCE_DESC_{}", source_name),
        source_name.span(),
    );

    quote! {
        #input

        impl #source_name {
            #(#component_consts)*
        }

        #[allow(non_upper_case_globals)]
        static #descriptor_static: &'static str = #descriptor_lit;

        #[allow(non_snake_case)]
        #[unsafe(no_mangle)]
        pub extern "C" fn #descriptor_fn() -> u64 {
            let len = #descriptor_static.len() as u64;
            let ptr = #descriptor_static.as_ptr() as usize as u64;
            (ptr << 32) | len
        }

        #(#mapper_exports)*
    }
    .into()
}

#[proc_macro_attribute]
pub fn component(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let input = syn::parse_macro_input!(item as Item);

    match input {
        Item::Struct(item_struct) => expand_component_struct(item_struct).into(),
        Item::Enum(item_enum) => expand_component_enum(item_enum).into(),
        _ => syn::Error::new_spanned(input, "#[component] only supports structs and enums")
            .to_compile_error()
            .into(),
    }
}

#[proc_macro_attribute]
pub fn rule(attr: TokenStream, item: TokenStream) -> TokenStream {
    let args = syn::parse_macro_input!(attr as RuleArgs);
    let input = syn::parse_macro_input!(item as ItemFn);
    let rule_fn_name = input.sig.ident.clone();
    let watch_json = args
        .watch
        .iter()
        .map(|item| format!(r#""{}""#, item))
        .collect::<Vec<_>>()
        .join(",");
    let descriptor_json = format!(
        r#"{{"name":"{}","watch":[{}],"priority":{}}}"#,
        rule_fn_name, watch_json, args.priority
    );
    let descriptor_lit = syn::LitStr::new(&descriptor_json, rule_fn_name.span());
    let descriptor_fn = Ident::new(
        &format!("__slung_rule_{}_descriptor", rule_fn_name),
        rule_fn_name.span(),
    );
    let entrypoint_fn = Ident::new(
        &format!("__slung_rule_{}", rule_fn_name),
        rule_fn_name.span(),
    );
    let descriptor_static = Ident::new(
        &format!("__RULE_DESC_{}", rule_fn_name),
        rule_fn_name.span(),
    );

    let invoke = match input.sig.inputs.len() {
        0 => quote! { #rule_fn_name() },
        1 => quote! {
            {
                let __slung_ctx = ::slung::RuleContext::default();
                #rule_fn_name(&__slung_ctx)
            }
        },
        _ => {
            return syn::Error::new_spanned(
                &input.sig.inputs,
                "#[rule] functions must take zero arguments or `&RuleContext`",
            )
            .to_compile_error()
            .into();
        }
    };

    quote! {
        #input

        #[allow(non_upper_case_globals)]
        static #descriptor_static: &'static str = #descriptor_lit;

        #[allow(non_snake_case)]
        #[unsafe(no_mangle)]
        pub extern "C" fn #descriptor_fn() -> u64 {
            let len = #descriptor_static.len() as u64;
            let ptr = #descriptor_static.as_ptr() as usize as u64;
            (ptr << 32) | len
        }

        #[allow(non_snake_case)]
        #[unsafe(no_mangle)]
        pub extern "C" fn #entrypoint_fn() -> i32 {
            match #invoke {
                Ok(()) => 0,
                Err(_) => 1,
            }
        }
    }
    .into()
}

fn strip_source_field_attrs(attrs: &mut Vec<Attribute>) -> SourceFieldMeta {
    let mut meta = SourceFieldMeta::default();
    let mut keep = Vec::new();

    for attr in attrs.drain(..) {
        if attr.path().is_ident("config") {
            meta.is_config = true;
            continue;
        }

        if attr.path().is_ident("component") {
            if let Meta::List(list) = &attr.meta {
                let parsed = list
                    .parse_args_with(Punctuated::<Meta, Token![,]>::parse_terminated)
                    .unwrap_or_default();

                for item in parsed {
                    if let Meta::NameValue(name_value) = item
                        && name_value.path.is_ident("map")
                        && let Expr::Path(ExprPath { path, .. }) = name_value.value
                        && let Some(mapper) = path.get_ident()
                    {
                        meta.mapper = Some(mapper.clone());
                    }
                }
            }
            continue;
        }

        keep.push(attr);
    }

    *attrs = keep;
    meta
}

fn type_name(ty: &Type) -> String {
    match ty {
        Type::Path(path) => path
            .path
            .segments
            .last()
            .map(|segment| segment.ident.to_string())
            .unwrap_or_else(|| "Unknown".to_string()),
        _ => "Unknown".to_string(),
    }
}

fn expand_component_struct(input: ItemStruct) -> proc_macro2::TokenStream {
    let component_name = input.ident.clone();
    let field_names = match &input.fields {
        Fields::Named(fields) => fields
            .named
            .iter()
            .filter_map(|field| field.ident.as_ref().map(ToString::to_string))
            .collect::<Vec<_>>(),
        _ => Vec::new(),
    };

    let descriptor_json = format!(
        r#"{{"name":"{}","kind":"struct","fields":[{}]}}"#,
        component_name,
        field_names
            .iter()
            .map(|field| format!(r#""{}""#, field))
            .collect::<Vec<_>>()
            .join(",")
    );

    expand_component_item(
        quote! {
            #[derive(::serde::Serialize, ::serde::Deserialize, Debug, Clone)]
            #input
        },
        &component_name,
        descriptor_json,
    )
}

fn expand_component_enum(input: ItemEnum) -> proc_macro2::TokenStream {
    let component_name = input.ident.clone();
    let variants = input
        .variants
        .iter()
        .map(|variant| variant.ident.to_string())
        .collect::<Vec<_>>();
    let descriptor_json = format!(
        r#"{{"name":"{}","kind":"enum","fields":[],"variants":[{}]}}"#,
        component_name,
        variants
            .iter()
            .map(|variant| format!(r#""{}""#, variant))
            .collect::<Vec<_>>()
            .join(",")
    );

    expand_component_item(
        quote! {
            #[derive(::serde::Serialize, ::serde::Deserialize, Debug, Clone)]
            #input
        },
        &component_name,
        descriptor_json,
    )
}

fn expand_component_item(
    item: proc_macro2::TokenStream,
    component_name: &Ident,
    descriptor_json: String,
) -> proc_macro2::TokenStream {
    let descriptor_lit = syn::LitStr::new(&descriptor_json, component_name.span());
    let descriptor_fn = Ident::new(
        &format!("__slung_component_{}_descriptor", component_name),
        component_name.span(),
    );
    let descriptor_static = Ident::new(
        &format!("__COMPONENT_DESC_{}", component_name),
        component_name.span(),
    );

    quote! {
        #item

        #[allow(non_upper_case_globals)]
        static #descriptor_static: &'static str = #descriptor_lit;

        #[allow(non_snake_case)]
        #[unsafe(no_mangle)]
        pub extern "C" fn #descriptor_fn() -> u64 {
            let len = #descriptor_static.len() as u64;
            let ptr = #descriptor_static.as_ptr() as usize as u64;
            (ptr << 32) | len
        }
    }
}

fn expr_to_watch_string(expr: &Expr) -> Result<String> {
    match expr {
        Expr::Path(path) => Ok(quote!(#path).to_string().replace(' ', "")),
        Expr::Lit(ExprLit {
            lit: Lit::Str(value),
            ..
        }) => Ok(value.value()),
        _ => Err(syn::Error::new_spanned(
            expr,
            "watch entries must be paths like `Source::field` or string literals",
        )),
    }
}
