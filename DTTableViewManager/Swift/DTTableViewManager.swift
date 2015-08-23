//
//  TableViewController.swift
//  DTTableViewManager
//
//  Created by Denys Telezhkin on 12.07.15.
//  Copyright (c) 2015 Denys Telezhkin. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import UIKit
import DTModelStorage

/// Adopting this protocol will automatically inject manager property to your object, that lazily instantiates DTTableViewManager object.
/// Target is not required to be UITableViewController, and can be a regular UIViewController with UITableView, or even different object like UICollectionViewCell.
public protocol DTTableViewManageable : NSObjectProtocol
{
    /// Table view, that will be managed by DTTableViewManager
    var tableView : UITableView! { get }
}

private var DTTableViewManagerAssociatedKey = "Manager Associated Key"

/// Default implementation for `DTTableViewManageable` protocol, that will inject `manager` property to any object, that declares itself `DTTableViewManageable`.
extension DTTableViewManageable
{
    /// Lazily instantiated `DTTableViewManager` instance. When your table view is loaded, call startManagingWithDelegate: method and `DTTableViewManager` will take over UITableView datasource and delegate. Any method, that is not implemented by `DTTableViewManager`, will be forwarded to delegate.
    /// - SeeAlso: `startManagingWithDelegate:`
    public var manager : DTTableViewManager
    {
        get {
            var object = objc_getAssociatedObject(self, &DTTableViewManagerAssociatedKey)
            if object == nil {
                object = DTTableViewManager()
                objc_setAssociatedObject(self, &DTTableViewManagerAssociatedKey, object, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            return object as! DTTableViewManager
        }
        set {
            objc_setAssociatedObject(self, &DTTableViewManagerAssociatedKey, newValue, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

/// `DTTableViewManager` manages some of `UITableView` datasource and delegate methods and provides API for managing your data models in the table. Any method, that is not implemented by `DTTableViewManager`, will be forwarded to delegate.
/// - SeeAlso: `startManagingWithDelegate:`
public class DTTableViewManager : NSObject {
    
    var tableView : UITableView!
    {
        return self.delegate?.tableView
    }
    
    weak var delegate : DTTableViewManageable?

    ///  Factory for creating cells and views for UITableView
    private lazy var cellFactory: TableViewFactory = {
        precondition(self.tableView != nil, "Please call manager.startManagingWithDelegate(self) before calling any other DTTableViewManager methods")
        return TableViewFactory(tableView: self.tableView)
    }()
    
    /// Bundle to search your xib's in. This can sometimes be useful for unit-testing. Defaults to NSBundle.mainBundle()
    public var viewBundle = NSBundle.mainBundle()
    {
        didSet {
            cellFactory.bundle = viewBundle
        }
    }
    
    /// Stores all configuration options for `DTTableViewManager`.
    /// - SeeAlso: `TableViewConfiguration`.
    public var configuration = TableViewConfiguration()
    
    /// Array of reactions for `DTTableViewManager`
    /// - SeeAlso: `TableViewReaction`.
    var tableViewReactions = [TableViewReaction]()
    
    func reactionOfReactionType(type: TableViewReactionType, forCellType cellType: _MirrorType?) -> TableViewReaction?
    {
        return self.tableViewReactions.filter({ (reaction) -> Bool in
            return reaction.reactionType == type && reaction.cellType?.summary == cellType?.summary
        }).first
    }
    
    /// Implicitly unwrap storage property to `MemoryStorage`.
    /// - Warning: if storage is not MemoryStorage, will throw an exception.
    public var memoryStorage : MemoryStorage!
    {
        precondition(storage is MemoryStorage, "DTTableViewController memoryStorage method should be called only if you are using MemoryStorage")
        
        return storage as! MemoryStorage
    }
    
    /// Storage, that holds your UITableView models. By default, it's `MemoryStorage` instance.
    /// - Note: When setting custom storage for this property, it will be automatically configured for using with UITableView and it's delegate will be set to `DTTableViewManager` instance.
    /// - Note: Previous storage `delegate` property will be nilled out to avoid collisions.
    /// - SeeAlso: `MemoryStorage`, `CoreDataStorage`.
    public var storage : StorageProtocol = {
        let storage = MemoryStorage()
        storage.configureForTableViewUsage()
        return storage
    }()
    {
        willSet {
            // explicit self is required due to known bug in Swift compiler - https://devforums.apple.com/message/1065306#1065306
            self.storage.delegate = nil
        }
        didSet {
            if let headerFooterCompatibleStorage = storage as? BaseStorage {
                headerFooterCompatibleStorage.configureForTableViewUsage()
            }
            storage.delegate = self
        }
    }
    
    /// Call this method before calling any of `DTTableViewManager` methods.
    /// - Precondition: UITableView instance on `delegate` should not be nil.
    /// - Parameter delegate: Object, that has UITableView, that will be managed by `DTTableViewManager`.
    public func startManagingWithDelegate(delegate : DTTableViewManageable)
    {
        precondition(delegate.tableView != nil,"Call startManagingWithDelegate: method only when UITableView has been created")
        
        self.delegate = delegate
        delegate.tableView.delegate = self
        delegate.tableView.dataSource = self
    }
    
    /// Call this method to retrieve model from specific UITableViewCell subclass.
    /// - Note: This method uses UITableView `indexPathForCell` method, that returns nil if cell is not visible. Therefore, if cell is not visible, this method will return nil as well.
    /// - SeeAlso: `StorageProtocol` method `objectForCell:atIndexPath:` - will return model even if cell is not visible
    public func objectForCell<T:ModelTransfer where T:UITableViewCell>(cell:T?) -> T.ModelType?
    {
        guard cell != nil else {  return nil }
        
        if let indexPath = self.tableView.indexPathForCell(cell!) {
            return storage.objectAtIndexPath(indexPath) as? T.ModelType
        }
        return nil
    }
    
    func headerModelForSectionIndex(index: Int) -> Any?
    {
        if self.storage.sections[index].numberOfObjects == 0 && !configuration.displayHeaderOnEmptySection
        {
            return nil
        }
        return (self.storage as? HeaderFooterStorageProtocol)?.headerModelForSectionIndex(index)
    }
    
    func footerModelForSectionIndex(index: Int) -> Any?
    {
        if self.storage.sections[index].numberOfObjects == 0 && !configuration.displayFooterOnEmptySection
        {
            return nil
        }
        return (self.storage as? HeaderFooterStorageProtocol)?.footerModelForSectionIndex(index)
    }
}

// MARK: - Runtime forwarding
extension DTTableViewManager
{
    /// Any `UITableViewDatasource` and `UITableViewDelegate` method, that is not implemented by `DTTableViewManager` will be redirected to delegate, if it implements it.
    public override func forwardingTargetForSelector(aSelector: Selector) -> AnyObject? {
        return delegate
    }
    
    /// Any `UITableViewDatasource` and `UITableViewDelegate` method, that is not implemented by `DTTableViewManager` will be redirected to delegate, if it implements it.
    public override func respondsToSelector(aSelector: Selector) -> Bool {
        if self.delegate?.respondsToSelector(aSelector) ?? false {
            return true
        }
        return super.respondsToSelector(aSelector)
    }
}

// MARK: - Cell registration
extension DTTableViewManager
{
    /// Register mapping from model class to custom cell class. Method will automatically check for nib with the same name as `cellType`. If it exists - nib will be registered instead of class.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter cellType: Type of UITableViewCell subclass, that is being registered for using by `DTTableViewManager`
    public func registerCellClass<T:ModelTransfer where T: UITableViewCell>(cellType:T.Type)
    {
        self.cellFactory.registerCellClass(cellType)
    }
    
    /// This method combines registerCellClass and whenSelected: methods together.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter cellType: Type of UITableViewCell subclass, that is being registered for using by `DTTableViewManager`
    /// - Parameter selectionClosure: closure to run when UITableViewCell is selected
    /// - Note: selectionClosure will be stored on `DTTableViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTTableViewManager` property in capture lists.
    /// - SeeAlso: `registerCellClass`, `whenSelected` methods
    public func registerCellClass<T:ModelTransfer where T:UITableViewCell>(cellType: T.Type,
        selectionClosure: (T,T.ModelType, NSIndexPath) -> Void)
    {
        self.cellFactory.registerCellClass(cellType)
        self.whenSelected(cellType, selectionClosure)
    }

    /// Register mapping from model class to custom cell class using specific nib file.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter nibName: Name of xib file to use
    /// - Parameter cellType: Type of UITableViewCell subclass, that is being registered for using by `DTTableViewManager`
    public func registerNibNamed<T:ModelTransfer where T: UITableViewCell>(nibName: String, forCellType cellType: T.Type)
    {
        self.cellFactory.registerNibNamed(nibName, forCellType: cellType)
    }
    
    /// Register mapping from model class to custom header view class. Method will automatically check for nib with the same name as `headerType`. If it exists - nib will be registered instead of class.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter headerType: Type of UITableViewCell subclass, that is being registered for using by `DTTableViewManager`
    public func registerHeaderClass<T:ModelTransfer where T: UIView>(headerType : T.Type)
    {
        configuration.sectionHeaderStyle = .View
        self.cellFactory.registerHeaderClass(headerType)
    }
    
    /// Register mapping from model class to custom footer view class. Method will automatically check for nib with the same name as `footerType`. If it exists - nib will be registered instead of class.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter footerType: Type of UITableViewCell subclass, that is being registered for using by `DTTableViewManager`
    public func registerFooterClass<T:ModelTransfer where T:UIView>(footerType: T.Type)
    {
        configuration.sectionFooterStyle = .View
        cellFactory.registerFooterClass(footerType)
    }
    
    /// Register mapping from model class to custom header class using specific nib file.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter nibName: Name of xib file to use
    /// - Parameter headerType: Type of UIView or UITableReusableView subclass, that is being registered for using by `DTTableViewManager`
    public func registerNibNamed<T:ModelTransfer where T:UIView>(nibName: String, forHeaderType headerType: T.Type)
    {
        configuration.sectionHeaderStyle = .View
        cellFactory.registerNibNamed(nibName, forHeaderType: headerType)
    }
    
    /// Register mapping from model class to custom footer class using specific nib file.
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Parameter nibName: Name of xib file to use
    /// - Parameter footerType: Type of UIView or UITableReusableView subclass, that is being registered for using by `DTTableViewManager`
    public func registerNibNamed<T:ModelTransfer where T:UIView>(nibName: String, forFooterType footerType: T.Type)
    {
        configuration.sectionFooterStyle = .View
        cellFactory.registerNibNamed(nibName, forFooterType: footerType)
    }
    
}

// MARK: - Table view reactions
extension DTTableViewManager
{
    /// Define an action, that will be performed, when cell of specific type is selected.
    /// - Parameter cellClass: Type of UITableViewCell subclass
    /// - Parameter closure: closure to run when UITableViewCell is selected
    /// - Note: Model type is automatically gathered from `ModelTransfer`.`ModelType` associated type.
    /// - Note: Closure will be stored on `DTTableViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTTableViewManager` property in capture lists.
    /// - SeeAlso: `registerCellClass:selectionClosure` method
    public func whenSelected<T:ModelTransfer where T:UITableViewCell>(cellClass:  T.Type, _ closure: (T,T.ModelType, NSIndexPath) -> Void)
    {
        let reaction = TableViewReaction(reactionType: .Selection)
        reaction.cellType = _reflect(T)
        reaction.reactionBlock = { [weak self, reaction] in
            if let indexPath = reaction.reactionData as? NSIndexPath,
                let cell = self?.tableView.cellForRowAtIndexPath(indexPath),
                let model = self?.storage.objectAtIndexPath(indexPath)
            {
                closure(cell as! T, model as! T.ModelType, indexPath)
            }
        }
        self.tableViewReactions.append(reaction)
    }
    
    /// Define additional configuration action, that will happen, when UITableViewCell subclass is requested by UITableView. This action will be performed *after* cell is created and updateWithModel: method is called.
    /// - Parameter cellClass: Type of UITableViewCell subclass
    /// - Parameter closure: closure to run when UITableViewCell is being configured
    /// - Note: Closure will be stored on `DTTableViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTTableViewManager` property in capture lists.
    public func configureCell<T:ModelTransfer where T: UITableViewCell>(cellClass:T.Type, _ closure: (T, T.ModelType, NSIndexPath) -> Void)
    {
        let reaction = TableViewReaction(reactionType: .CellConfiguration)
        reaction.cellType = _reflect(T)
        reaction.reactionBlock = { [weak self, reaction] in
            if let configuration = reaction.reactionData as? CellConfiguration,
                let model = self?.storage.objectAtIndexPath(configuration.indexPath)
            {
                closure(configuration.cell as! T, model as! T.ModelType, configuration.indexPath)
            }
        }
        self.tableViewReactions.append(reaction)
    }
    
    /// Define additional configuration action, that will happen, when UIView header subclass is requested by UITableView. This action will be performed *after* header is created and updateWithModel: method is called.
    /// - Parameter headerClass: Type of UIView or UITableReusableView subclass
    /// - Parameter closure: closure to run when UITableReusableView is being configured
    /// - Note: Closure will be stored on `DTTableViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTTableViewManager` property in capture lists.
    public func configureHeader<T:ModelTransfer where T: UIView>(headerClass: T.Type, _ closure: (T, T.ModelType, NSInteger) -> Void)
    {
        let reaction = TableViewReaction(reactionType: .HeaderConfiguration)
        reaction.cellType = _reflect(T)
        reaction.reactionBlock = { [weak self, reaction] in
            if let configuration = reaction.reactionData as? ViewConfiguration,
                let headerStorage = self?.storage as? HeaderFooterStorageProtocol,
                let model = headerStorage.headerModelForSectionIndex(configuration.sectionIndex)
            {
                closure(configuration.view as! T, model as! T.ModelType, configuration.sectionIndex)
            }
        }
        self.tableViewReactions.append(reaction)
    }
    
    /// Define additional configuration action, that will happen, when UIView footer subclass is requested by UITableView. This action will be performed *after* footer is created and updateWithModel: method is called.
    /// - Parameter footerClass: Type of UIView or UITableReusableView subclass
    /// - Parameter closure: closure to run when UITableReusableView is being configured
    /// - Note: Closure will be stored on `DTTableViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTTableViewManager` property in capture lists.
    public func configureFooter<T:ModelTransfer where T: UIView>(footerClass: T.Type, _ closure: (T, T.ModelType, NSInteger) -> Void)
    {
        let reaction = TableViewReaction(reactionType: .FooterConfiguration)
        reaction.cellType = _reflect(T)
        reaction.reactionBlock = { [weak self, reaction] in
            if let configuration = reaction.reactionData as? ViewConfiguration,
                let footerStorage = self?.storage as? HeaderFooterStorageProtocol,
                let model = footerStorage.footerModelForSectionIndex(configuration.sectionIndex)
            {
                closure(configuration.view as! T, model as! T.ModelType, configuration.sectionIndex)
            }
        }
        self.tableViewReactions.append(reaction)
    }
    
    /// Perform action before content will be updated.
    /// - Note: Closure will be stored on `DTTableViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTTableViewManager` property in capture lists.
    public func beforeContentUpdate(block: () -> Void )
    {
        let reaction = TableViewReaction(reactionType: .ControllerWillUpdateContent)
        reaction.reactionBlock = block
        self.tableViewReactions.append(reaction)
    }
    
    /// Perform action after content is updated.
    /// - Note: Closure will be stored on `DTTableViewManager` instance, which can create a retain cycle, so make sure to declare weak self and any other `DTTableViewManager` property in capture lists.
    public func afterContentUpdate(block : () -> Void )
    {
        let reaction = TableViewReaction(reactionType: .ControllerDidUpdateContent)
        reaction.reactionBlock = block
        self.tableViewReactions.append(reaction)
    }
}

// MARK: - UITableViewDatasource
extension DTTableViewManager: UITableViewDataSource
{
    public func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.storage.sections[section].numberOfObjects
    }
    
    public func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return self.storage.sections.count
    }
    
    public func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let model = self.storage.objectAtIndexPath(indexPath)!
        let cell = self.cellFactory.cellForModel(model, atIndexPath: indexPath)
        
        if let reaction = self.reactionOfReactionType(.CellConfiguration, forCellType: _reflect(cell.dynamicType)) {
            reaction.reactionData = CellConfiguration(cell:cell, indexPath:indexPath)
            reaction.perform()
        }
        return cell
    }
    
    public func tableView(tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if configuration.sectionHeaderStyle == .View { return nil }
        
        return self.headerModelForSectionIndex(section) as? String
    }
    
    public func tableView(tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if configuration.sectionFooterStyle == .View { return nil }
        
        return self.footerModelForSectionIndex(section) as? String
    }
    
    public func tableView(tableView: UITableView, moveRowAtIndexPath sourceIndexPath: NSIndexPath, toIndexPath destinationIndexPath: NSIndexPath) {
        if let storage = self.storage as? MemoryStorage
        {
            if let from = storage.sections[sourceIndexPath.section] as? SectionModel,
               let to = storage.sections[destinationIndexPath.section] as? SectionModel
            {
                    let item = from.objects[sourceIndexPath.row]
                    
                    from.objects.removeAtIndex(sourceIndexPath.row)
                    to.objects.insert(item, atIndex: destinationIndexPath.row)
            }
        }
    }
}

// MARK: - UITableViewDelegate
extension DTTableViewManager: UITableViewDelegate
{
    public func tableView(tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if configuration.sectionHeaderStyle == .Title { return nil }
        
        if let model = self.headerModelForSectionIndex(section) {
            let view = self.cellFactory.headerViewForModel(model)
            if let reaction = self.reactionOfReactionType(.HeaderConfiguration, forCellType: _reflect(view!.dynamicType)),
                let createdView = view
            {
                reaction.reactionData = ViewConfiguration(view: createdView, sectionIndex: section)
                reaction.perform()
            }
            return view
        }
        return nil
    }
    
    public func tableView(tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        if configuration.sectionFooterStyle == .Title { return nil }
        
        if let model = self.footerModelForSectionIndex(section) {
            let view = self.cellFactory.footerViewForModel(model)
            if let reaction = self.reactionOfReactionType(.FooterConfiguration, forCellType: _reflect(view!.dynamicType)),
                let createdView = view
            {
                reaction.reactionData = ViewConfiguration(view: createdView, sectionIndex: section)
                reaction.perform()
            }
            return view
        }
        return nil
    }
    
    public func tableView(tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if configuration.sectionHeaderStyle == .Title {
            if let _ = self.headerModelForSectionIndex(section) {
                return UITableViewAutomaticDimension
            }
            return CGFloat.min
        }
        
        if let _ = self.headerModelForSectionIndex(section) {
            return self.tableView.sectionHeaderHeight
        }
        return CGFloat.min
    }
    
    public func tableView(tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        if configuration.sectionFooterStyle == .Title {
            if let _ = self.footerModelForSectionIndex(section) {
                return UITableViewAutomaticDimension
            }
            return CGFloat.min
        }
        
        if let _ = self.footerModelForSectionIndex(section) {
            return self.tableView.sectionFooterHeight
        }
        return CGFloat.min
    }
    
    public func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        let cell = tableView.cellForRowAtIndexPath(indexPath)!
        if let reaction = self.reactionOfReactionType(.Selection, forCellType: _reflect(cell.dynamicType)) {
            reaction.reactionData = indexPath
            reaction.perform()
        }
    }
}

// MARK: - StorageUpdating
extension DTTableViewManager : StorageUpdating
{
    public func storageDidPerformUpdate(update : StorageUpdate)
    {
        self.controllerWillUpdateContent()

        tableView.beginUpdates()
        
        tableView.deleteSections(update.deletedSectionIndexes, withRowAnimation: configuration.deleteSectionAnimation)
        tableView.insertSections(update.insertedSectionIndexes, withRowAnimation: configuration.insertSectionAnimation)
        tableView.reloadSections(update.updatedSectionIndexes, withRowAnimation: configuration.reloadSectionAnimation)
        
        tableView.deleteRowsAtIndexPaths(update.deletedRowIndexPaths, withRowAnimation: configuration.deleteRowAnimation)
        tableView.insertRowsAtIndexPaths(update.insertedRowIndexPaths, withRowAnimation: configuration.insertRowAnimation)
        tableView.reloadRowsAtIndexPaths(update.updatedRowIndexPaths, withRowAnimation: configuration.reloadRowAnimation)
        
        tableView.endUpdates()
        
        self.controllerDidUpdateContent()
    }
    
    /// Call this method, if you want UITableView to be reloaded, and beforeContentUpdate: and afterContentUpdate: closures to be called.
    public func storageNeedsReloading()
    {
        self.controllerWillUpdateContent()
        tableView.reloadData()
        self.controllerDidUpdateContent()
    }
    
    func controllerWillUpdateContent()
    {
        if let reaction = self.reactionOfReactionType(.ControllerWillUpdateContent, forCellType: nil)
        {
            reaction.perform()
        }
    }
    
    func controllerDidUpdateContent()
    {
        if let reaction = self.reactionOfReactionType(.ControllerDidUpdateContent, forCellType: nil)
        {
            reaction.perform()
        }
    }
}

extension DTTableViewManager : TableViewStorageUpdating
{
    /// Perform animations you need for changes in UITableView. Method can be used for complex animations, that should be run simultaneously. 
    /// - Parameter block: animation block, that will be called
    public func performAnimatedUpdate(block: UITableView -> Void) {
        block(self.tableView)
    }
}