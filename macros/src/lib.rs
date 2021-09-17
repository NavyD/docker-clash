extern crate proc_macro;
use proc_macro::TokenStream;
use proc_macro2::{Ident, Span};
use quote::quote;
use syn::{parse_macro_input, Data, DataStruct, DeriveInput, Fields, Type};

// extern crate proc_macro;
// use proc_macro::TokenStream;

#[proc_macro]
pub fn make_answer(_item: TokenStream) -> TokenStream {
    "fn answer() -> u32 { 42 }".parse().unwrap()
}

/// 添加一个fn，从另一个Self实例移动所有字段，如果有字段是Option，则使用
///
/// ```ignore
/// pub fn fill(&mut self, other: Self) {
///     self.field = other.field;
///     if self.field.is_none() {
///         self.field = other.field
///     }
/// }
/// ```
#[proc_macro_derive(FillFn)]
pub fn derive_fill_fn(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;
    let (impl_generics, ty_generics, where_clause) = &input.generics.split_for_impl();

    let fileds = match &input.data {
        Data::Struct(DataStruct {
            fields: Fields::Named(fields),
            ..
        }) => &fields.named,
        _ => panic!("only supported struct fields"),
    };

    let arg_name = Ident::new("other", Span::call_site());

    let body = fileds.iter().map(|f| {
        let fname = f.ident.clone().unwrap();
        match &f.ty {
            Type::Path(p)
                if p.path.segments.last().map(|seg| seg.ident.to_string())
                    == Some("Option".to_string()) =>
            {
                // let path_str = p.path.segments.iter().fold(String::new(), |mut acc, seg| {
                //     acc.push_str(&seg.ident.to_string());
                //     acc.push_str("::");
                //     acc
                // });
                quote! {
                        if self.#fname.is_none() {
                            self.#fname = #arg_name.#fname;
                    }
                }
            }
            _ => quote! {
                self.#fname = #arg_name.#fname;
            },
        }

        // let val = match &f.ty {
        //     Type::Array(_) => "1",
        //     Type::BareFn(_) => "2",
        //     Type::Group(_) => "3",
        //     Type::ImplTrait(_) => "4",
        //     Type::Infer(_) => "5",
        //     Type::Macro(_) => "6",
        //     Type::Never(_) => "7",
        //     Type::Paren(_) => "8",
        //     Type::Path(_) => "9",
        //     Type::Ptr(_) => "10",
        //     Type::Reference(_) => "11",
        //     Type::Slice(_) => "12",
        //     Type::TraitObject(_) => "13",
        //     Type::Tuple(_) => "14",
        //     Type::Verbatim(_) => "15",
        //     Type::__TestExhaustive(_) => "16",
        // };
    });

    TokenStream::from(quote! {
        impl #impl_generics #name #ty_generics #where_clause {
            pub fn fill_if_some(&mut self, #arg_name: Self) {
                #(
                    #body
                )*
            }
        }
    })
}
