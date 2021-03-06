// Copyright (c) 2019, Facebook, Inc.
// All rights reserved.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the "hack" directory of this source tree.
use super::{node::Node, node_mut::NodeMut, visitor::Visitor, visitor_mut::VisitorMut};
use ocamlrep::rc::RcOc;
use std::collections::BTreeMap;

macro_rules! leaf_node {
    ($ty:ty) => {
        impl<Context, Error, Ex, Fb, En, Hi> Node<Context, Error, Ex, Fb, En, Hi> for $ty {}
        impl<Context, Error, Ex, Fb, En, Hi> NodeMut<Context, Error, Ex, Fb, En, Hi> for $ty {}
    };
}

leaf_node!(bool);
leaf_node!(isize);
leaf_node!(String);
leaf_node!(crate::pos::Pos);
leaf_node!(crate::file_info::Mode);
leaf_node!(crate::namespace_env::Env);

impl<Context, Error, Ex, Fb, En, Hi, T> Node<Context, Error, Ex, Fb, En, Hi> for Vec<T>
where
    T: Node<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &self,
        c: &mut Context,
        v: &mut dyn Visitor<Context = Context, Error = Error, Ex = Ex, Fb = Fb, En = En, Hi = Hi>,
    ) -> Result<(), Error> {
        Ok(for i in self {
            i.accept(c, v)?;
        })
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T> NodeMut<Context, Error, Ex, Fb, En, Hi> for Vec<T>
where
    T: NodeMut<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &mut self,
        c: &mut Context,
        v: &mut dyn VisitorMut<
            Context = Context,
            Error = Error,
            Ex = Ex,
            Fb = Fb,
            En = En,
            Hi = Hi,
        >,
    ) -> Result<(), Error> {
        Ok(for i in self {
            i.accept(c, v)?;
        })
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T> Node<Context, Error, Ex, Fb, En, Hi> for Option<T>
where
    T: Node<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &self,
        c: &mut Context,
        v: &mut dyn Visitor<Context = Context, Error = Error, Ex = Ex, Fb = Fb, En = En, Hi = Hi>,
    ) -> Result<(), Error> {
        Ok(match self {
            Some(t) => t.accept(c, v)?,
            _ => (),
        })
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T> NodeMut<Context, Error, Ex, Fb, En, Hi> for Option<T>
where
    T: NodeMut<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &mut self,
        c: &mut Context,
        v: &mut dyn VisitorMut<
            Context = Context,
            Error = Error,
            Ex = Ex,
            Fb = Fb,
            En = En,
            Hi = Hi,
        >,
    ) -> Result<(), Error> {
        Ok(match self {
            Some(t) => t.accept(c, v)?,
            _ => (),
        })
    }
}

impl<Context, Error, Ex, Fb, En, Hi, K, V> Node<Context, Error, Ex, Fb, En, Hi> for BTreeMap<K, V>
where
    V: Node<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &self,
        c: &mut Context,
        v: &mut dyn Visitor<Context = Context, Error = Error, Ex = Ex, Fb = Fb, En = En, Hi = Hi>,
    ) -> Result<(), Error> {
        Ok(for value in self.values() {
            value.accept(c, v)?;
        })
    }
}

impl<Context, Error, Ex, Fb, En, Hi, K, V> NodeMut<Context, Error, Ex, Fb, En, Hi>
    for BTreeMap<K, V>
where
    V: NodeMut<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &mut self,
        c: &mut Context,
        v: &mut dyn VisitorMut<
            Context = Context,
            Error = Error,
            Ex = Ex,
            Fb = Fb,
            En = En,
            Hi = Hi,
        >,
    ) -> Result<(), Error> {
        Ok(for value in self.values_mut() {
            value.accept(c, v)?;
        })
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T> Node<Context, Error, Ex, Fb, En, Hi> for RcOc<T>
where
    T: Node<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &self,
        c: &mut Context,
        v: &mut dyn Visitor<Context = Context, Error = Error, Ex = Ex, Fb = Fb, En = En, Hi = Hi>,
    ) -> Result<(), Error> {
        self.as_ref().accept(c, v)
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T> NodeMut<Context, Error, Ex, Fb, En, Hi> for RcOc<T>
where
    T: NodeMut<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &mut self,
        c: &mut Context,
        v: &mut dyn VisitorMut<
            Context = Context,
            Error = Error,
            Ex = Ex,
            Fb = Fb,
            En = En,
            Hi = Hi,
        >,
    ) -> Result<(), Error> {
        Ok(if let Some(x) = RcOc::get_mut(self) {
            x.accept(c, v)?;
        })
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T> Node<Context, Error, Ex, Fb, En, Hi> for std::rc::Rc<T>
where
    T: Node<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &self,
        c: &mut Context,
        v: &mut dyn Visitor<Context = Context, Error = Error, Ex = Ex, Fb = Fb, En = En, Hi = Hi>,
    ) -> Result<(), Error> {
        self.as_ref().accept(c, v)
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T> NodeMut<Context, Error, Ex, Fb, En, Hi> for std::rc::Rc<T>
where
    T: NodeMut<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &mut self,
        c: &mut Context,
        v: &mut dyn VisitorMut<
            Context = Context,
            Error = Error,
            Ex = Ex,
            Fb = Fb,
            En = En,
            Hi = Hi,
        >,
    ) -> Result<(), Error> {
        Ok(if let Some(x) = std::rc::Rc::get_mut(self) {
            x.accept(c, v)?;
        })
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T> Node<Context, Error, Ex, Fb, En, Hi> for Box<T>
where
    T: Node<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &self,
        c: &mut Context,
        v: &mut dyn Visitor<Context = Context, Error = Error, Ex = Ex, Fb = Fb, En = En, Hi = Hi>,
    ) -> Result<(), Error> {
        self.as_ref().accept(c, v)
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T> NodeMut<Context, Error, Ex, Fb, En, Hi> for Box<T>
where
    T: NodeMut<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &mut self,
        c: &mut Context,
        v: &mut dyn VisitorMut<
            Context = Context,
            Error = Error,
            Ex = Ex,
            Fb = Fb,
            En = En,
            Hi = Hi,
        >,
    ) -> Result<(), Error> {
        self.as_mut().accept(c, v)
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T1, T2> Node<Context, Error, Ex, Fb, En, Hi> for (T1, T2)
where
    T1: Node<Context, Error, Ex, Fb, En, Hi>,
    T2: Node<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &self,
        c: &mut Context,
        v: &mut dyn Visitor<Context = Context, Error = Error, Ex = Ex, Fb = Fb, En = En, Hi = Hi>,
    ) -> Result<(), Error> {
        self.0.accept(c, v)?;
        self.1.accept(c, v)
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T1, T2, T3> Node<Context, Error, Ex, Fb, En, Hi>
    for (T1, T2, T3)
where
    T1: Node<Context, Error, Ex, Fb, En, Hi>,
    T2: Node<Context, Error, Ex, Fb, En, Hi>,
    T3: Node<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &self,
        c: &mut Context,
        v: &mut dyn Visitor<Context = Context, Error = Error, Ex = Ex, Fb = Fb, En = En, Hi = Hi>,
    ) -> Result<(), Error> {
        self.0.accept(c, v)?;
        self.1.accept(c, v)?;
        self.2.accept(c, v)
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T1, T2, T3, T4> Node<Context, Error, Ex, Fb, En, Hi>
    for (T1, T2, T3, T4)
where
    T1: Node<Context, Error, Ex, Fb, En, Hi>,
    T2: Node<Context, Error, Ex, Fb, En, Hi>,
    T3: Node<Context, Error, Ex, Fb, En, Hi>,
    T4: Node<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &self,
        c: &mut Context,
        v: &mut dyn Visitor<Context = Context, Error = Error, Ex = Ex, Fb = Fb, En = En, Hi = Hi>,
    ) -> Result<(), Error> {
        self.0.accept(c, v)?;
        self.1.accept(c, v)?;
        self.2.accept(c, v)?;
        self.3.accept(c, v)
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T1, T2> NodeMut<Context, Error, Ex, Fb, En, Hi> for (T1, T2)
where
    T1: NodeMut<Context, Error, Ex, Fb, En, Hi>,
    T2: NodeMut<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &mut self,
        c: &mut Context,
        v: &mut dyn VisitorMut<
            Context = Context,
            Error = Error,
            Ex = Ex,
            Fb = Fb,
            En = En,
            Hi = Hi,
        >,
    ) -> Result<(), Error> {
        self.0.accept(c, v)?;
        self.1.accept(c, v)
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T1, T2, T3> NodeMut<Context, Error, Ex, Fb, En, Hi>
    for (T1, T2, T3)
where
    T1: NodeMut<Context, Error, Ex, Fb, En, Hi>,
    T2: NodeMut<Context, Error, Ex, Fb, En, Hi>,
    T3: NodeMut<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &mut self,
        c: &mut Context,
        v: &mut dyn VisitorMut<
            Context = Context,
            Error = Error,
            Ex = Ex,
            Fb = Fb,
            En = En,
            Hi = Hi,
        >,
    ) -> Result<(), Error> {
        self.0.accept(c, v)?;
        self.1.accept(c, v)?;
        self.2.accept(c, v)
    }
}

impl<Context, Error, Ex, Fb, En, Hi, T1, T2, T3, T4> NodeMut<Context, Error, Ex, Fb, En, Hi>
    for (T1, T2, T3, T4)
where
    T1: NodeMut<Context, Error, Ex, Fb, En, Hi>,
    T2: NodeMut<Context, Error, Ex, Fb, En, Hi>,
    T3: NodeMut<Context, Error, Ex, Fb, En, Hi>,
    T4: NodeMut<Context, Error, Ex, Fb, En, Hi>,
{
    fn recurse(
        &mut self,
        c: &mut Context,
        v: &mut dyn VisitorMut<
            Context = Context,
            Error = Error,
            Ex = Ex,
            Fb = Fb,
            En = En,
            Hi = Hi,
        >,
    ) -> Result<(), Error> {
        self.0.accept(c, v)?;
        self.1.accept(c, v)?;
        self.2.accept(c, v)?;
        self.3.accept(c, v)
    }
}
