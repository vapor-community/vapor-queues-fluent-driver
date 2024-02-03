import protocol FluentKit.Fields
import protocol FluentKit.Schema
import enum FluentKit.FieldKey
import protocol FluentKit.QueryAddressableProperty
import struct FluentSQL.SQLQualifiedTable
import struct SQLKit.SQLIdentifier
import struct SQLKit.SQLColumn

extension FluentKit.Fields {
    static func key<P>(for keypath: KeyPath<Self, P>) -> FieldKey
        where P: QueryAddressableProperty
    {
        Self.init()[keyPath: keypath].queryablePath[0]
    }

    static func sqlColumnName<P>(_ keypath: KeyPath<Self, P>) -> SQLIdentifier
        where P: QueryAddressableProperty
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
        where P: QueryAddressableProperty
    {
        .init(
            Self.sqlColumnName(keypath),
            table: Self.sqlTable
        )
    }
}
