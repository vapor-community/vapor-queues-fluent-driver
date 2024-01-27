import FluentKit
import FluentSQL
import SQLKit

extension FluentKit.Fields {
    static func key<P>(for keypath: KeyPath<Self, P>) -> FieldKey
        where P: QueryAddressableProperty, P.Model == Self
    {
        Self.path(for: keypath.appending(path: \.queryableProperty))[0]
    }

    static func sqlColumnName<P>(_ keypath: KeyPath<Self, P>) -> SQLIdentifier
        where P: QueryAddressableProperty, P.Model == Self
    {
        SQLIdentifier(Self.key(for: keypath).description)
    }
}

extension FluentKit.Schema {
    static var sqlTable: SQLQualifiedTable {
        .init(
            SQLIdentifier(Self.schemaOrAlias),
            space: (Self.alias == nil ? Self.space : nil).map(SQLIdentifier.init(_:))
        )
    }
    
    static func sqlColumn<P>(_ keypath: KeyPath<Self, P>) -> SQLColumn
        where P: QueryAddressableProperty, P.Model == Self
    {
        .init(
            Self.sqlColumnName(keypath),
            table: Self.sqlTable
        )
    }
}
