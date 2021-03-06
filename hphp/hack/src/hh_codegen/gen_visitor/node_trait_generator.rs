// Copyright (c) 2019, Facebook, Inc.
// All rights reserved.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the "hack" directory of this source tree.

use super::{context::Context, gen_helper::*, generator::Generator};
use crate::{common::*, impl_generator};
use proc_macro2::TokenStream;
use quote::{format_ident, quote};

trait NodeTrait {
    fn filename() -> String;
    fn trait_name() -> syn::Ident;
    fn receiver() -> TokenStream;
    fn visitor() -> syn::Ident;
    fn use_visitor() -> TokenStream;

    fn gen(ctx: &Context) -> Result<TokenStream> {
        let ty_params = gen_ty_params(ctx.root_ty_params_with_context());
        let ty_param_bindings = gen_ty_param_bindings(ctx.root_ty_params_with_context());
        let trait_name = Self::trait_name();
        let receiver = Self::receiver();
        let visitor = Self::visitor();
        let use_visitor = Self::use_visitor();
        let context = ctx.context_ident();
        let error = ctx.error_ident();
        Ok(quote! {
            #![allow(unused_variables)]
            #use_visitor

            pub trait #trait_name#ty_params {
                fn accept(
                    #receiver,
                    ctx: &mut #context,
                    v: &mut dyn #visitor#ty_param_bindings,
                ) -> Result<(), #error> {
                    self.recurse(ctx, v)
                }

                fn recurse(
                    #receiver,
                    ctx: &mut #context,
                    v: &mut dyn #visitor#ty_param_bindings,
                ) -> Result<(), #error> {
                    Ok(())
                }
            }
        })
    }
}

pub struct RefNodeTrait;
impl NodeTrait for RefNodeTrait {
    fn filename() -> String {
        "node.rs".into()
    }

    fn trait_name() -> syn::Ident {
        format_ident!("Node")
    }

    fn receiver() -> TokenStream {
        quote! {&self}
    }

    fn visitor() -> syn::Ident {
        format_ident!("Visitor")
    }

    fn use_visitor() -> TokenStream {
        quote! { use super::visitor::Visitor; }
    }
}
impl_generator!(RefNodeTrait, NodeTrait);

pub struct MutNodeTrait;
impl NodeTrait for MutNodeTrait {
    fn filename() -> String {
        "node_mut.rs".into()
    }

    fn trait_name() -> syn::Ident {
        format_ident!("NodeMut")
    }

    fn receiver() -> TokenStream {
        quote! {&mut self}
    }

    fn visitor() -> syn::Ident {
        format_ident!("VisitorMut")
    }

    fn use_visitor() -> TokenStream {
        quote! { use super::visitor_mut::VisitorMut; }
    }
}
impl_generator!(MutNodeTrait, NodeTrait);
