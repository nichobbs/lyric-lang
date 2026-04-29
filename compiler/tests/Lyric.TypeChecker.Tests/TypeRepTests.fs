module Lyric.TypeChecker.Tests.TypeRepTests

open Expecto
open Lyric.TypeChecker

let tests =
    testList "type representation" [

        test "primitive types are equal to themselves" {
            Expect.equal Type.int' Type.int' "Int = Int"
            Expect.notEqual Type.int' Type.long' "Int ≠ Long"
        }

        test "rendering produces the §4.1 names" {
            Expect.equal (Type.render Type.int')    "Int"    "Int"
            Expect.equal (Type.render Type.bool')   "Bool"   "Bool"
            Expect.equal (Type.render Type.string') "String" "String"
            Expect.equal (Type.render Type.unit')   "Unit"   "Unit"
        }

        test "compatible accepts equality, error wildcard, and Never" {
            Expect.isTrue  (Type.compatible Type.int' Type.int') "Int↔Int"
            Expect.isTrue  (Type.compatible Type.error' Type.int') "error↔Int"
            Expect.isTrue  (Type.compatible Type.int' Type.error') "Int↔error"
            Expect.isTrue  (Type.compatible Type.never' Type.int') "Never↔Int"
            Expect.isFalse (Type.compatible Type.int' Type.bool') "Int↮Bool"
        }

        test "nullable subsumes its inner type" {
            let nullableInt = Type.TyNullable Type.int'
            Expect.isTrue (Type.compatible nullableInt Type.int') "Int? accepts Int"
            Expect.isFalse (Type.compatible nullableInt Type.bool') "Int? rejects Bool"
        }

        test "substitution replaces type variables" {
            let f = Type.TyFunction([Type.TyVar "A"], Type.TyVar "A")
            let s = Map.ofList ["A", Type.int']
            let f' = Type.subst s f
            Expect.equal f' (Type.TyFunction([Type.int'], Type.int'))
                "(A) -> A becomes (Int) -> Int"
        }

        test "function types compare structurally" {
            let f1 = Type.TyFunction([Type.int'], Type.bool')
            let f2 = Type.TyFunction([Type.int'], Type.bool')
            Expect.equal f1 f2 "(Int) -> Bool equal"
            let f3 = Type.TyFunction([Type.long'], Type.bool')
            Expect.notEqual f1 f3 "(Int) -> Bool ≠ (Long) -> Bool"
        }
    ]
