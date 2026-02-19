use proc_macro::TokenStream;
use quote::{quote, quote_spanned};
use syn::spanned::Spanned;
use syn::{Ident, ItemFn, parse_macro_input};

/// Entry point for Wasm functions.
#[proc_macro_attribute]
pub fn main(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let ItemFn {
        attrs,
        vis,
        mut sig,
        block,
    } = parse_macro_input!(item as ItemFn);

    if sig.asyncness.is_some() {
        return quote!(compile_error!("async functions are not supported")).into();
    }

    let orig_ident = sig.ident.clone();
    let new_ident = Ident::new(&format!("__{orig_ident}"), sig.ident.span());
    sig.ident = new_ident.clone();

    let main_impl = quote_spanned! {sig.output.span()=>
        #[cfg(target_arch = "wasm32")]
        #[unsafe(no_mangle)]
        pub extern "C" fn call() -> i32 {
            let result = std::panic::catch_unwind(|| {
                #new_ident()
            });

            match result {
                Ok(Ok(())) => 0,  // Success
                Ok(Err(e)) => {
                    eprintln!("Error: {}", e);
                    1  // Error from function
                },
                Err(e) => {
                    eprintln!("Runtime panic: {:?}", e);
                    2  // Panic
                }
            }
        }

        fn main() {
            // Native main that does nothing but satisfy the compiler
            let result = #new_ident();
            match result {
                Ok(()) => {},
                Err(e) => eprintln!("Error: {}", e),
            }
        }
    };

    quote! {
        #(#attrs)*
        #vis #sig #block

        #main_impl
    }
    .into()
}
